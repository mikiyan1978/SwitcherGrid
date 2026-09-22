// StayForeground feature, merged into SwitcherGrid's own dylib (originally a
// separate tweak + its own Prefs bundle). The separate StayForegroundPrefs
// Settings screen turned out to reliably crash Preferences.app on this
// device (repeated EXC_BAD_ACCESS/SIGBUS inside Apple's own closed-source
// -[PSListController specifierAtIndex:]/clearCache, even after fixing the
// arm64e slice and every AltList config knob) despite KillGuard's own
// AltList-based picker in the SAME process working fine. Root cause was
// never pinned down; the user's decision was to stop chasing it and fold
// the feature into SwitcherGrid instead, reusing SwitcherGrid's already-
// stable Settings screen and its shared "ProtectedBundleIDs" app catalog
// (KillGuard.xm) rather than maintaining a second, separate picker.
//
// Mechanism: our first implementation only cleared
// -[UIMutableApplicationSceneSettings setDeactivationReasons:] to 0 inside
// -[FBScene updateSettings:withTransitionContext:completion:], then still
// called %orig unconditionally. Confirmed on-device (2026-09-22) that alone
// does NOT keep a Google Drive upload alive across backgrounding.
//
// Ported from com.sergy.immortalizer's actual open-source Tweak.xm
// (github.com/sergealagon/Immortalizer, fetched 2026-09-22) instead of
// continuing to guess. Their real implementation combines three hooks; we
// use the first two below (the third, -setKillable: on
// SBFluidSwitcherItemContainer, was tried and reverted -- see KillGuard.xm,
// it broke single-app swipe-kill):
//   1. FBScene -updateSettings:withTransitionContext:completion: skips
//      %orig ENTIRELY (does not call the original at all) when the
//      transition context argument is nil and the scene's app is protected
//      -- not just mutating the settings object beforehand.
//   2. UIMutableApplicationSceneSettings -setDeactivationReasons: refuses
//      to apply any *non-zero* value, unconditionally (no per-app check
//      inside this method at all -- the scoping instead comes from hook #1
//      only letting a protected app's settings object reach this call with
//      arg2==nil in the first place; for everything else %orig still runs
//      normally).
//
// CONFIRMED WORKING on-device (2026-09-22) with just these two hooks (no
// setKillable: needed): BGBeacon (a from-scratch test app with no
// background modes declared, ~/iOSTweaks/BGBeacon) keeps its 1-second
// repeating beep going while backgrounded when its bundle ID is protected +
// StayForeground is enabled, and silent (normal iOS behavior) when not
// protected. Google Drive's upload also continued across backgrounding
// under the same conditions, where it previously restarted from scratch
// under the incomplete first implementation above.
//
// This feature has its own master on/off switch (StayForegroundEnabled, in
// SwitcherGrid's own com.mikiyan1978.switchergrid defaults, toggled from
// Root.plist) but reads the SAME shared ProtectedBundleIDs catalog as
// KillGuard for which apps it applies to -- one picker, two independent
// protections.

#import <Foundation/Foundation.h>
#import <CoreFoundation/CoreFoundation.h>
#import <objc/message.h>
#include <string.h>
#include <sys/stat.h>

extern const char *getprogname(void);

#define SF_LOG_PATH "/var/mobile/Documents/stayforeground.log"
#define SF_CONFIG_PATH @"/var/mobile/Library/Preferences/com.mikiyan1978.appguardian.plist"
#define SF_SWITCHERGRID_PREFS_PATH @"/var/mobile/Library/Preferences/com.mikiyan1978.switchergrid.plist"

static void SFWriteLog(NSString *format, ...) {
    FILE *f = fopen(SF_LOG_PATH, "a");
    if (!f) return;
    va_list args;
    va_start(args, format);
    NSString *message = [[NSString alloc] initWithFormat:format arguments:args];
    va_end(args);
    NSString *line = [NSString stringWithFormat:@"[%@][%s] %@\n", [NSDate date], getprogname(), message];
    fputs([line UTF8String], f);
    fclose(f);
}

#pragma mark - Config

static NSArray<NSString *> *gSFWatchedApps = nil; // bundle IDs, shared catalog
static BOOL gSFFeatureEnabled = YES;
static time_t gSFConfigMtime = 0;
static time_t gSFPrefsMtime = 0;

static time_t SFFileMtime(NSString *path) {
    struct stat st;
    if (stat([path fileSystemRepresentation], &st) != 0) return 0;
    return st.st_mtime;
}

static void SFLoadConfig(void) {
    NSDictionary *root = [NSDictionary dictionaryWithContentsOfFile:SF_CONFIG_PATH];
    NSArray *bundleIDs = root[@"ProtectedBundleIDs"];
    NSMutableArray *valid = [NSMutableArray array];
    for (id entry in bundleIDs) {
        if ([entry isKindOfClass:[NSString class]]) {
            [valid addObject:entry];
        }
    }
    gSFWatchedApps = [valid copy];
    gSFConfigMtime = SFFileMtime(SF_CONFIG_PATH);

    NSDictionary *prefs = [NSDictionary dictionaryWithContentsOfFile:SF_SWITCHERGRID_PREFS_PATH];
    id enabledValue = prefs[@"StayForegroundEnabled"];
    gSFFeatureEnabled = enabledValue ? [enabledValue boolValue] : YES;
    gSFPrefsMtime = SFFileMtime(SF_SWITCHERGRID_PREFS_PATH);

    SFWriteLog(@"LoadConfig: enabled=%d, %lu app(s) in shared catalog", gSFFeatureEnabled, (unsigned long)gSFWatchedApps.count);
}

static void SFRefreshConfigIfChanged(void) {
    time_t configMtime = SFFileMtime(SF_CONFIG_PATH);
    time_t prefsMtime = SFFileMtime(SF_SWITCHERGRID_PREFS_PATH);
    if ((configMtime != 0 && configMtime != gSFConfigMtime) ||
        (prefsMtime != 0 && prefsMtime != gSFPrefsMtime)) {
        SFLoadConfig();
    }
}

static BOOL SFIsWatchedBundleID(NSString *bundleID) {
    return gSFFeatureEnabled && bundleID != nil && [gSFWatchedApps containsObject:bundleID];
}

#pragma mark - Scene identity

static NSString *SFSceneBundleIdentifier(id scene) {
    if (!scene) return nil;
    if ([scene respondsToSelector:@selector(clientProcess)]) {
        id (*fn)(id, SEL) = (id (*)(id, SEL))objc_msgSend;
        id process = fn(scene, @selector(clientProcess));
        if (process && [process respondsToSelector:@selector(bundleIdentifier)]) {
            id bundleID = fn(process, @selector(bundleIdentifier));
            if ([bundleID isKindOfClass:[NSString class]]) return bundleID;
        }
    }
    NSArray<NSString *> *candidates = @[@"bundleIdentifier", @"clientBundleIdentifier",
                                         @"identity", @"clientIdentity"];
    for (NSString *selName in candidates) {
        SEL sel = NSSelectorFromString(selName);
        if (![scene respondsToSelector:sel]) continue;
        id (*fn)(id, SEL) = (id (*)(id, SEL))objc_msgSend;
        id result = fn(scene, sel);
        if ([result isKindOfClass:[NSString class]]) return result;
    }
    return nil;
}

%group StayForegroundHooks

%hook FBScene

- (void)updateSettings:(id)settings withTransitionContext:(id)context completion:(void (^)(void))completion {
    SFRefreshConfigIfChanged();
    NSString *bundleID = SFSceneBundleIdentifier(self);
    if (SFIsWatchedBundleID(bundleID) && context == nil) {
        SFWriteLog(@"skipped updateSettings (nil context) for %@", bundleID);
        return;
    }
    %orig;
}

%end

// No per-app check here by design (matches Immortalizer's actual
// implementation): refusing any non-zero value system-wide is what's
// documented upstream. Scoping to protected apps happens one level up, in
// FBScene's hook above -- for everything else, updateSettings: still runs
// %orig normally and reaches this setter the same way it always did.
%hook UIMutableApplicationSceneSettings

- (void)setDeactivationReasons:(NSUInteger)reasons {
    if (reasons != 0) {
        return;
    }
    %orig;
}

%end

%end // StayForegroundHooks

%ctor {
    if (strcmp(getprogname(), "SpringBoard") != 0) {
        return;
    }
    SFLoadConfig();
    %init(StayForegroundHooks);
    SFWriteLog(@"StayForeground (merged into SwitcherGrid) ctor loaded, enabled=%d, watching %lu app(s)",
               gSFFeatureEnabled, (unsigned long)gSFWatchedApps.count);
}
