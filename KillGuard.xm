// KillGuard: SwitcherGrid's "protect selected apps from being killed"
// feature. Originally built and tested as a standalone project
// (AppGuardian) before being folded into SwitcherGrid, since the switcher
// (grid layout + kill-all) and kill-prevention are the same problem space
// -- both live entirely in SpringBoard's app-switcher machinery and share
// the same SBFluidSwitcherItemContainer/appLayout plumbing.
//
// Scope, deliberately narrow: this file ONLY prevents the process from
// being killed while the user is looking at the switcher (single swipe-
// kill, and SwitcherGrid's own kill-all). It does NOT try to keep the app
// out of the background or extend its background execution time -- that
// is a separate, not-yet-solved problem (see the sibling StayForeground
// project). It also does NOT auto-relaunch a killed app -- an earlier
// version of this code did (a launchd daemon, "Layer A"), but on-device
// testing showed a relaunched process starts fresh and doesn't resume
// whatever background work was interrupted, so it wasn't actually solving
// the real problem; removed rather than carried forward.
//
// Primary defense mechanism, found by disassembling a real published
// tweak (com.sergy.immortalizer, analyzed 2026-09-21): hook
// -[SBFluidSwitcherItemContainer setKillable:] and force NO for protected
// apps -- this changes whether the switcher's own model considers the app
// killable at all, upstream of any kill request being issued. Confirmed
// on-device this blocks a normal single-app swipe-kill. SwitcherGrid's own
// kill-all (killContainer:forReason:) was found to bypass that entirely
// (it force-kills unconditionally, never consulting isKillable), so it
// gets its own hook too -- see killContainer:forReason: below.
//
// Bundle-ID identification: the container has no direct bundleIdentifier
// accessor, but does have -appLayout, and SBAppLayout has
// -containsItemWithBundleIdentifier: (found via a read-only class/method
// probe run against this exact SpringBoard build).

#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>
#include <string.h>
#include <sys/stat.h>
#include <sys/sysctl.h>
#include <errno.h>
#include <signal.h>
#include <dlfcn.h>

extern const char *getprogname(void);

// Defined in Tweak.x (same dylib) -- see the comment there for why this
// exists: killContainer:forReason: is the same real method a genuine
// single-app swipe-kill calls, so this hook alone can't distinguish that
// from SwitcherGrid's own kill-all sweep without an explicit signal.
extern BOOL gSGKillAllInProgress;

// SpringBoard runs as "mobile", and /var/log is root:wheel 755 -- mobile
// has no write permission there, so fopen() there silently fails (looks
// exactly like "the ctor never ran" from the outside). /var/mobile/Documents
// is mobile:mobile and writable.
#define KG_LOG_PATH "/var/mobile/Documents/killguard.log"
// Shared with a sibling project (StayForeground) intentionally -- both
// protect the same user-picked app list, just with different mechanisms
// (this file blocks kills; StayForeground blocks backgrounding), so they
// read the same catalog rather than making the user pick apps twice.
#define KG_CONFIG_PATH @"/var/mobile/Library/Preferences/com.mikiyan1978.appguardian.plist"

static void KGWriteLog(NSString *format, ...) {
    FILE *f = fopen(KG_LOG_PATH, "a");
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
//
// Schema: a plain NSArray<NSString> of protected bundle IDs under key
// "ProtectedBundleIDs" -- this is AltList's (com.opa334.altlist)
// -[ATLApplicationListMultiSelectionController loadPreferences]/
// -savePreferences format (the same "detail=ATLApplicationListMulti
// SelectionController, key=..., defaults=..." PSSpecifier convention
// com.sergy.immortalizer's own Settings screen used), reusing its proper
// native multi-select app picker in Settings instead of a hand-rolled
// PSListController subclass -- an earlier custom implementation crashed
// Preferences.app on-device (2026-09-22) for reasons not fully diagnosed;
// AltList's own picker is a real, tested, widely-used component instead
// of guessing at PSListController internals a second time.
//
// No richer per-app metadata (ProcessName/URLScheme) is persisted anymore
// -- AltList's picker only knows about bundle IDs. Anything needing that
// metadata (jetsam boost, relaunch fallback) derives it on demand from
// each app's own Info.plist via KGDeriveAppMetadata, with a small cache
// since it's now looked up more often than just on long-press.
static NSArray<NSString *> *gKGWatchedApps = nil; // bundle IDs
static time_t gKGConfigMtime = 0;
static NSMutableDictionary<NSString *, NSDictionary *> *gKGMetadataCache = nil;

static time_t KGConfigFileMtime(void) {
    struct stat st;
    if (stat([KG_CONFIG_PATH fileSystemRepresentation], &st) != 0) {
        return 0;
    }
    return st.st_mtime;
}

static void KGLoadConfig(void) {
    NSDictionary *root = [NSDictionary dictionaryWithContentsOfFile:KG_CONFIG_PATH];
    NSArray *bundleIDs = root[@"ProtectedBundleIDs"];
    NSMutableArray *valid = [NSMutableArray array];
    for (id entry in bundleIDs) {
        if ([entry isKindOfClass:[NSString class]]) {
            [valid addObject:entry];
        }
    }
    gKGWatchedApps = [valid copy];
    gKGConfigMtime = KGConfigFileMtime();
    gKGMetadataCache = [NSMutableDictionary dictionary]; // config changed -- don't trust stale metadata
    KGWriteLog(@"LoadConfig: %lu app(s) in ProtectedBundleIDs", (unsigned long)gKGWatchedApps.count);
}

// The long-press toggle (this file) and AltList's own Settings picker (a
// separate process) both write straight to this file -- cheap to check
// mtime on every %hook firing.
static void KGRefreshConfigIfChanged(void) {
    time_t mtime = KGConfigFileMtime();
    if (mtime != 0 && mtime != gKGConfigMtime) {
        KGLoadConfig();
    }
}

static void KGWriteConfigToDisk(void) {
    NSDictionary *existingRoot = [NSDictionary dictionaryWithContentsOfFile:KG_CONFIG_PATH];
    NSMutableDictionary *root = existingRoot ? [existingRoot mutableCopy] : [NSMutableDictionary dictionary];
    root[@"ProtectedBundleIDs"] = gKGWatchedApps;
    BOOL ok = [root writeToFile:KG_CONFIG_PATH atomically:YES];
    gKGConfigMtime = KGConfigFileMtime();
    KGWriteLog(@"WriteConfigToDisk: wrote %lu bundle ID(s), ok=%d", (unsigned long)gKGWatchedApps.count, ok);
}

// Scans installed app bundles for one matching bundleID and reads its
// CFBundleExecutable (the actual process name shown in the process table,
// which is not reliably the same string as the bundle ID) and, if
// present, a URL scheme to use as the relaunch fallback elsewhere in this
// project. Cached per bundle ID (invalidated on config reload) since this
// can now be called from the jetsam-boost timer, not just a rare
// long-press.
static NSDictionary *KGDeriveAppMetadata(NSString *bundleID) {
    NSDictionary *cached = gKGMetadataCache[bundleID];
    if (cached) return cached;

    NSString *processName = nil, *urlScheme = nil;
    NSString *appsDir = @"/var/containers/Bundle/Application";
    NSFileManager *fm = [NSFileManager defaultManager];
    for (NSString *containerName in [fm contentsOfDirectoryAtPath:appsDir error:nil]) {
        NSString *containerPath = [appsDir stringByAppendingPathComponent:containerName];
        for (NSString *item in [fm contentsOfDirectoryAtPath:containerPath error:nil]) {
            if (![item hasSuffix:@".app"]) continue;
            NSString *infoPlistPath = [[containerPath stringByAppendingPathComponent:item]
                                        stringByAppendingPathComponent:@"Info.plist"];
            NSDictionary *info = [NSDictionary dictionaryWithContentsOfFile:infoPlistPath];
            if (!info || ![info[@"CFBundleIdentifier"] isEqualToString:bundleID]) continue;

            processName = info[@"CFBundleExecutable"];
            for (NSDictionary *type in info[@"CFBundleURLTypes"]) {
                NSArray *schemes = type[@"CFBundleURLSchemes"];
                if ([schemes.firstObject isKindOfClass:[NSString class]]) {
                    urlScheme = [NSString stringWithFormat:@"%@://", schemes.firstObject];
                    break;
                }
            }
            break;
        }
        if (processName) break;
    }

    NSMutableDictionary *result = [NSMutableDictionary dictionary];
    if (processName) result[@"ProcessName"] = processName;
    if (urlScheme) result[@"URLScheme"] = urlScheme;
    gKGMetadataCache[bundleID] = result;
    return result;
}

// Toggles protection for bundleID (add if absent, remove if present).
// Returns the new protected state.
static NSNumber *KGToggleEnabledForBundleID(NSString *bundleID) {
    KGRefreshConfigIfChanged();
    BOOL currentlyProtected = [gKGWatchedApps containsObject:bundleID];
    if (currentlyProtected) {
        NSMutableArray *updated = [gKGWatchedApps mutableCopy];
        [updated removeObject:bundleID];
        gKGWatchedApps = [updated copy];
    } else {
        gKGWatchedApps = [gKGWatchedApps arrayByAddingObject:bundleID];
    }
    KGWriteConfigToDisk();
    KGWriteLog(@"ToggleEnabledForBundleID: %@ -> %d", bundleID, !currentlyProtected);
    return @(!currentlyProtected);
}

#pragma mark - Stop lingering audio after a genuine kill
//
// User report (2026-09-21): killing Spotify (a protected app, but via a
// normal single swipe-kill this file deliberately allows through) leaves
// audio audibly playing for several seconds afterward. On-device
// diagnosis ruled out the initially-assumed cause: this was NOT a stale
// nowplayingd-cache bug (that WAS the right diagnosis for a different
// scenario in this project's retired AudioWatchdog experiment, but not
// this one) -- checks at 0.3s through 12s after killContainer:forReason:
// showed the process staying genuinely alive for 5-7s, and nowplayingd's
// isPlaying/PID fields tracked the real process state accurately the
// whole time, transitioning cleanly from "1/alive" straight to "0/gone"
// with no stale window to catch. The real cause: killContainer:forReason:
// triggers an asynchronous teardown (likely RunningBoard/runningboardd
// XPC) that can take 5-7+ seconds to actually complete, and audio
// legitimately keeps playing for as long as the process is genuinely
// still alive.
//
// Fix: don't wait to detect death at all -- send a Pause command the
// INSTANT a kill is requested, optimistically, before the real
// termination even starts. The user swiping to kill an app is already
// unambiguous intent to stop it, so there's no need to wait for
// confirmation.
typedef Boolean (*KGMRSendCommand_t)(NSInteger command, id userInfo);

static KGMRSendCommand_t gKGMRSendCommand;
static const NSInteger kKGMRCommandPause = 1; // MRMediaRemoteCommandPause

static void KGResolveMediaRemoteSymbols(void) {
    // A daemon-style process has no image that happens to pull MediaRemote
    // in on its own (confirmed in the AudioWatchdog experiment); SpringBoard
    // itself does link things that pull it in, but dlopen-by-path first is
    // cheap insurance and matches what already worked before.
    void *handle = dlopen("/System/Library/PrivateFrameworks/MediaRemote.framework/MediaRemote", RTLD_NOW);
    gKGMRSendCommand = (KGMRSendCommand_t)dlsym(RTLD_DEFAULT, "MRMediaRemoteSendCommand");
    KGWriteLog(@"MediaRemote symbols: dlopen handle=%p, sendCommand=%p", handle, gKGMRSendCommand);
}

static void KGPauseImmediatelyOnKill(void) {
    if (!gKGMRSendCommand) return;
    Boolean sendResult = gKGMRSendCommand(kKGMRCommandPause, nil);
    KGWriteLog(@"kill requested -- sent immediate Pause, MRMediaRemoteSendCommand returned %d", sendResult);
}

#pragma mark - Jetsam priority boost
//
// No separate daemon needed for this -- memorystatus_control is a plain
// libsystem_kernel.dylib syscall wrapper (real export, just undeclared in
// the public SDK headers), callable directly from SpringBoard's own
// process on a timer. Boosts each currently-running protected app to the
// same jetsam priority band the actual foreground app runs at, so jetsam
// picks off every other background app before even considering these.
extern "C" int memorystatus_control(uint32_t command, int32_t pid, uint32_t flags,
                                     void *buffer, size_t buffersize);
#define KG_MEMORYSTATUS_CMD_SET_PRIORITY_PROPERTIES 6
#define KG_JETSAM_PRIORITY_FOREGROUND 16

struct kg_memorystatus_priority_properties {
    int32_t priority;
    int32_t user_data;
};

static pid_t KGFindPIDByName(const char *name) {
    int mib[4] = { CTL_KERN, KERN_PROC, KERN_PROC_ALL, 0 };
    size_t size = 0;
    if (sysctl(mib, 4, NULL, &size, NULL, 0) != 0) return 0;
    size += size / 4;
    struct kinfo_proc *procs = (struct kinfo_proc *)malloc(size);
    if (!procs) return 0;
    if (sysctl(mib, 4, procs, &size, NULL, 0) != 0) { free(procs); return 0; }
    pid_t found = 0;
    int count = (int)(size / sizeof(struct kinfo_proc));
    for (int i = 0; i < count; i++) {
        if (strcmp(procs[i].kp_proc.p_comm, name) == 0) { found = procs[i].kp_proc.p_pid; break; }
    }
    free(procs);
    return found;
}

static void KGBoostJetsamPriorityForWatchedApps(void) {
    KGRefreshConfigIfChanged();
    for (NSString *bundleID in gKGWatchedApps) {
        NSString *processName = KGDeriveAppMetadata(bundleID)[@"ProcessName"];
        if (![processName isKindOfClass:[NSString class]] || processName.length == 0) continue;
        pid_t pid = KGFindPIDByName([processName UTF8String]);
        if (pid <= 0) continue;
        struct kg_memorystatus_priority_properties props = { KG_JETSAM_PRIORITY_FOREGROUND, 0 };
        memorystatus_control(KG_MEMORYSTATUS_CMD_SET_PRIORITY_PROPERTIES, pid, 0, &props, sizeof(props));
    }
}

#pragma mark - Bundle ID lookup helpers

static NSString *KGBundleIDInSwitcherContainer(id container) {
    if (!container || ![container respondsToSelector:@selector(appLayout)]) return nil;
    id (*appLayoutFn)(id, SEL) = (id (*)(id, SEL))objc_msgSend;
    id appLayout = appLayoutFn(container, @selector(appLayout));
    if (!appLayout || ![appLayout respondsToSelector:@selector(containsItemWithBundleIdentifier:)]) return nil;
    BOOL (*containsFn)(id, SEL, NSString *) = (BOOL (*)(id, SEL, NSString *))objc_msgSend;
    for (NSString *bundleID in gKGWatchedApps) {
        if (containsFn(appLayout, @selector(containsItemWithBundleIdentifier:), bundleID)) return bundleID;
    }
    return nil;
}

static NSString *KGWatchedBundleIDInSwitcherContainer(id container) {
    return KGBundleIDInSwitcherContainer(container);
}

// Unlike the catalog lookups above (which only ever *check membership* of
// bundle IDs we already know), this extracts whatever bundle ID a card
// actually displays, for ANY app -- needed so long-press can protect an
// app that was never added to the catalog before. No single confirmed
// accessor for this was found via KillProbe, so this tries several
// plausible candidates and logs which one (if any) worked, in order of
// how likely/cheap each is.
// Bundle IDs never contain a colon or the literal substring "sceneID:", so
// any of those found in an identifier-shaped string are structural
// noise around the real bundle ID, not part of it -- strip them rather
// than trusting the raw string just because it happens to contain a dot.
// Handles shapes seen on-device: "card:<bundleID>:sceneID:<bundleID>-
// <suffix>" (accessibilityIdentifier) and "sceneID:<bundleID>-<suffix>"
// (continuousExposeIdentifier / destroyScene:'s scene argument).
static NSString *KGExtractBundleIDFromIdentifierString(NSString *s) {
    if (![s isKindOfClass:[NSString class]]) return nil;
    NSString *candidate = s;
    NSRange sceneRange = [candidate rangeOfString:@"sceneID:" options:NSBackwardsSearch];
    if (sceneRange.location != NSNotFound) {
        candidate = [candidate substringFromIndex:NSMaxRange(sceneRange)];
    }
    NSRange dashRange = [candidate rangeOfString:@"-" options:NSBackwardsSearch];
    if (dashRange.location != NSNotFound) {
        candidate = [candidate substringToIndex:dashRange.location];
    }
    if (candidate.length > 0
        && [candidate rangeOfString:@"."].location != NSNotFound
        && [candidate rangeOfString:@":"].location == NSNotFound) {
        return candidate;
    }
    return nil;
}

static NSString *KGDeriveArbitraryBundleID(id container) {
    if (!container) return nil;

    // 1. The card view's own accessibilityIdentifier -- UI-testing
    // identifiers on these cards often embed the bundle ID (confirmed
    // on-device shape: "card:<bundleID>:sceneID:<bundleID>-<suffix>").
    NSString *axCandidate = KGExtractBundleIDFromIdentifierString(
        [(UIView *)container accessibilityIdentifier]);
    if (axCandidate) return axCandidate;

    if (![container respondsToSelector:@selector(appLayout)]) return nil;
    id (*fn0)(id, SEL) = (id (*)(id, SEL))objc_msgSend;
    id appLayout = fn0(container, @selector(appLayout));
    if (!appLayout) return nil;

    // 2. appLayout itself, or an "item" fetched from its primary layout
    // role, might respond directly to bundleIdentifier.
    if ([appLayout respondsToSelector:@selector(bundleIdentifier)]) {
        id result = fn0(appLayout, @selector(bundleIdentifier));
        if ([result isKindOfClass:[NSString class]]) return result;
    }
    if ([appLayout respondsToSelector:@selector(itemForLayoutRole:)]) {
        id (*roleFn)(id, SEL, NSInteger) = (id (*)(id, SEL, NSInteger))objc_msgSend;
        id item = roleFn(appLayout, @selector(itemForLayoutRole:), 0);
        if (item && [item respondsToSelector:@selector(bundleIdentifier)]) {
            id result = fn0(item, @selector(bundleIdentifier));
            if ([result isKindOfClass:[NSString class]]) return result;
        }
    }

    // 3. continuousExposeIdentifier -- same sceneID:-prefixed shape.
    if ([appLayout respondsToSelector:@selector(continuousExposeIdentifier)]) {
        id result = fn0(appLayout, @selector(continuousExposeIdentifier));
        NSString *candidate = KGExtractBundleIDFromIdentifierString(result);
        if (candidate) return candidate;
    }

    KGWriteLog(@"DeriveArbitraryBundleID: no candidate worked for %@ / appLayout=%@", [container class], [appLayout class]);
    return nil;
}

#pragma mark - Long-press toggle (no visual switcher badge)

static const void *kKGLongPressKey = &kKGLongPressKey;

// History (2026-09-21, three separate approaches, each confirmed broken
// on-device via user screenshots): a badge as a direct subview of
// SBFluidSwitcherItemContainer, a separate overlay UIWindow tracking card
// positions, and badges added to the switcher's own top-level view --
// all three leaked into live foreground app content at some point. This
// iOS build's switcher view hierarchy behaves in a way not accounted for
// by any of those approaches, and without a real on-device view debugger
// (not available in this setup), further attempts would be more guessing.
//
// Decision: drop the visual indicator entirely. Protection state is still
// fully visible in Settings -> SwitcherGrid -> "Choose Protected Apps"
// (SGAppListController), and the long-press toggle keeps working with
// haptic-only feedback -- just without an on-card visual.

%group KillGuardHooks

%hook SBFluidSwitcherItemContainer

%new
- (void)kg_handleLongPress:(UILongPressGestureRecognizer *)gr {
    if (gr.state != UIGestureRecognizerStateBegan) return;
    KGRefreshConfigIfChanged();
    // Works on ANY app card, not just ones already in the catalog --
    // KGToggleEnabledForBundleID adds a fresh entry (protection defaulting
    // to on) the first time a not-yet-catalogued app is long-pressed.
    NSString *bundleID = KGDeriveArbitraryBundleID(self);
    if (!bundleID) {
        KGWriteLog(@"long-press: could not identify app for this card, ignoring");
        return;
    }
    NSNumber *newState = KGToggleEnabledForBundleID(bundleID);
    if (!newState) return;
    UIImpactFeedbackGenerator *haptic = [[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleMedium];
    [haptic prepare];
    [haptic impactOccurred];
    KGWriteLog(@"long-press toggled %@ -> %@", bundleID, newState.boolValue ? @"protected" : @"unprotected");
}

- (id)initWithFrame:(CGRect)frame appLayout:(id)appLayout delegate:(id)delegate
             active:(BOOL)active windowScene:(id)windowScene {
    self = %orig;
    if (self && !objc_getAssociatedObject(self, kKGLongPressKey)) {
        UILongPressGestureRecognizer *lp = [[UILongPressGestureRecognizer alloc]
            initWithTarget:self action:@selector(kg_handleLongPress:)];
        // 0.5s (a typical default) fired by accident during ordinary
        // switcher browsing on-device -- 1.2s plus the default 10pt
        // movement-cancel (built into UILongPressGestureRecognizer, so a
        // real swipe self-cancels this) is a much harder accidental hit.
        lp.minimumPressDuration = 1.2;
        [(UIView *)self addGestureRecognizer:lp];
        objc_setAssociatedObject(self, kKGLongPressKey, lp, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    return self;
}

// Tried porting com.sergy.immortalizer's -setKillable: hook here (forcing
// NO for protected apps, matching their open-source Tweak.xm) to back
// StayForeground's scene-level hooks. Reverted (2026-09-22): confirmed
// on-device this also blocks genuine single-app swipe-kill, which breaks
// the explicit, previously-established requirement that single swipe-kill
// must never be blocked -- only KillGuard's own kill-all path may block
// (see killContainer:forReason: below, gated on gSGKillAllInProgress).
// setKillable: apparently gates ANY kill path here, including the user's
// own swipe, with no way to distinguish "system reaping a backgrounded
// card" from "user swiped this card up" the way killContainer:forReason:
// can via gSGKillAllInProgress. Left unimplemented rather than reintroduce
// that regression; StayForeground's scene-level hooks (FBScene /
// UIMutableApplicationSceneSettings, in StayForeground.xm) still apply on
// their own, just without this third piece.

%end

// Deliberate scope, per explicit request (2026-09-21): protection now
// ONLY blocks SwitcherGrid's own "kill all" bulk action
// (sg_killAllContainers in Tweak.x calls killContainer:forReason:
// directly on every visible container, bypassing isKillable/setKillable:
// entirely -- a lower-level forced-kill path distinct from a normal
// single-app swipe). A normal single-app swipe-kill is deliberately left
// alone -- earlier versions of this file also hooked setKillable:,
// destroyScene:withTransitionContext:, and FBSSystemService's
// terminateApplication:... to block that too, but that removed the only
// way to kill a protected app on purpose, which turned out to be a real
// problem (no escape valve if you genuinely need to kill it). Those hooks
// were removed rather than kept-but-disabled, since dead blocking code
// with no current purpose is more confusing to find later than its
// absence.
%hook SBFluidSwitcherViewController

- (void)killContainer:(id)container forReason:(NSInteger)reason {
    // Without this check, a genuine single-app swipe-kill and SwitcherGrid's
    // own kill-all sweep both arrive here as the exact same call and can't
    // be told apart otherwise (confirmed on-device 2026-09-21: a plain
    // swipe was logging as "BLOCKED" even after this hook was supposedly
    // scoped to kill-all only).
    if (!gSGKillAllInProgress) {
        KGPauseImmediatelyOnKill();
        %orig;
        return;
    }
    KGRefreshConfigIfChanged();
    NSString *bundleID = KGWatchedBundleIDInSwitcherContainer(container);
    if (bundleID) {
        KGWriteLog(@"BLOCKED killContainer:forReason: for %@ (reason=%ld)", bundleID, (long)reason);
        return;
    }
    KGPauseImmediatelyOnKill();
    %orig;
}

%end

%end // KillGuardHooks

%ctor {
    if (strcmp(getprogname(), "SpringBoard") != 0) {
        return;
    }
    KGLoadConfig();
    KGResolveMediaRemoteSymbols();
    %init(KillGuardHooks);

    // Jetsam priority boost runs on a simple repeating timer rather than a
    // separate daemon -- one fewer moving part, and memorystatus_control
    // works fine called directly from SpringBoard's own process. Held in
    // a static so it isn't deallocated (a source with no strong owner is
    // invalidated under ARC) -- SpringBoard's process lifetime is this
    // timer's whole intended lifetime anyway, so it's never torn down.
    static dispatch_source_t sKGJetsamTimer;
    sKGJetsamTimer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, dispatch_get_main_queue());
    dispatch_source_set_timer(sKGJetsamTimer, dispatch_time(DISPATCH_TIME_NOW, 0), 5 * NSEC_PER_SEC, 1 * NSEC_PER_SEC);
    dispatch_source_set_event_handler(sKGJetsamTimer, ^{
        KGBoostJetsamPriorityForWatchedApps();
    });
    dispatch_resume(sKGJetsamTimer);

    KGWriteLog(@"KillGuard ctor loaded, protecting %lu app(s)", (unsigned long)gKGWatchedApps.count);
}
