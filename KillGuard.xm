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
#import <CoreFoundation/CoreFoundation.h>
#import <objc/runtime.h>
#import <objc/message.h>
#include <string.h>
#include <sys/stat.h>
#include <errno.h>
#include <signal.h>
#include <dlfcn.h>
#include <sys/sysctl.h>

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
static NSArray<NSString *> *gKGWatchedApps = nil; // bundle IDs
// int64 nanoseconds, not time_t (1-second resolution) -- confirmed on-device
// 2026-09-23 that a long-press toggle followed within the same wall-clock
// second by something checking protection could miss the change: st_mtime
// rounds to the second, so a write and a read landing in the same second
// compare equal even though the file changed, leaving the stale catalog
// cached until something touched the file again in a LATER second (in
// practice, only noticed after opening the Settings picker, which
// happened to re-save and bump the mtime a second time).
static int64_t gKGConfigMtimeNS = 0;

static int64_t KGConfigFileMtime(void) {
    struct stat st;
    if (stat([KG_CONFIG_PATH fileSystemRepresentation], &st) != 0) {
        return 0;
    }
    return (int64_t)st.st_mtimespec.tv_sec * 1000000000LL + st.st_mtimespec.tv_nsec;
}

// Forward declaration: real definition (with the sysctl-based PID lookup)
// lives further down, but KGLoadConfig needs to call it on every reload.
static void KGKillRunningAppByBundleID(NSString *bundleID);

static void KGLoadConfig(void) {
    NSArray<NSString *> *previousWatchedApps = gKGWatchedApps; // nil on the very first call
    NSDictionary *root = [NSDictionary dictionaryWithContentsOfFile:KG_CONFIG_PATH];
    NSArray *bundleIDs = root[@"ProtectedBundleIDs"];
    NSMutableArray *valid = [NSMutableArray array];
    for (id entry in bundleIDs) {
        if ([entry isKindOfClass:[NSString class]]) {
            [valid addObject:entry];
        }
    }
    gKGWatchedApps = [valid copy];
    gKGConfigMtimeNS = KGConfigFileMtime();
    KGWriteLog(@"LoadConfig: %lu app(s) in ProtectedBundleIDs", (unsigned long)gKGWatchedApps.count);

    // Protection state for a running app doesn't retroactively apply to its
    // already-connected scene -- kill it so its next launch picks up the
    // new config immediately (see KGKillRunningAppByBundleID for the full
    // reasoning). Skip this on the very first load (SpringBoard's own
    // %ctor, or the first refresh after a respring): previousWatchedApps
    // is nil then, and every app in an on-disk catalog would otherwise
    // read as "just added," killing every already-running protected app
    // for no reason right after every respring.
    if (previousWatchedApps) {
        NSMutableSet<NSString *> *changed = [NSMutableSet setWithArray:gKGWatchedApps];
        [changed minusSet:[NSSet setWithArray:previousWatchedApps]]; // newly protected
        NSMutableSet<NSString *> *noLongerWatched = [NSMutableSet setWithArray:previousWatchedApps];
        [noLongerWatched minusSet:[NSSet setWithArray:gKGWatchedApps]]; // newly unprotected
        [changed unionSet:noLongerWatched];
        for (NSString *bundleID in changed) {
            KGKillRunningAppByBundleID(bundleID);
        }
    }
}

// AltList's own Settings picker (a separate process) writes straight to
// this file -- cheap to check mtime on every %hook firing.
static void KGRefreshConfigIfChanged(void) {
    int64_t mtime = KGConfigFileMtime();
    if (mtime != 0 && mtime != gKGConfigMtimeNS) {
        KGLoadConfig();
    }
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
typedef void (*KGMRGetNowPlayingPID_t)(dispatch_queue_t queue, void (^handler)(int pid));

static KGMRSendCommand_t gKGMRSendCommand;
static KGMRGetNowPlayingPID_t gKGMRGetNowPlayingPID;
static const NSInteger kKGMRCommandPause = 1; // MRMediaRemoteCommandPause

static void KGResolveMediaRemoteSymbols(void) {
    // A daemon-style process has no image that happens to pull MediaRemote
    // in on its own (confirmed in the AudioWatchdog experiment); SpringBoard
    // itself does link things that pull it in, but dlopen-by-path first is
    // cheap insurance and matches what already worked before.
    void *handle = dlopen("/System/Library/PrivateFrameworks/MediaRemote.framework/MediaRemote", RTLD_NOW);
    gKGMRSendCommand = (KGMRSendCommand_t)dlsym(RTLD_DEFAULT, "MRMediaRemoteSendCommand");
    gKGMRGetNowPlayingPID = (KGMRGetNowPlayingPID_t)dlsym(RTLD_DEFAULT, "MRMediaRemoteGetNowPlayingApplicationPID");
    KGWriteLog(@"MediaRemote symbols: dlopen handle=%p, sendCommand=%p, getNowPlayingPID=%p", handle, gKGMRSendCommand, gKGMRGetNowPlayingPID);
}

static dispatch_queue_t KGMediaRemoteReplyQueue(void) {
    // Deliberately NOT dispatch_get_main_queue(): KGGetNowPlayingPIDSync
    // below blocks the calling thread (main, in practice -- killContainer:
    // runs there) waiting on this handler, so the handler must run
    // somewhere else or it deadlocks waiting for itself.
    static dispatch_queue_t q;
    static dispatch_once_t token;
    dispatch_once(&token, ^{
        q = dispatch_queue_create("com.mikiyan1978.killguard.mediaremote", DISPATCH_QUEUE_SERIAL);
    });
    return q;
}

// Blocking on purpose: killContainer: needs to know THIS SPECIFIC kill's
// target vs. Now Playing before deciding whether to pause, and there's no
// good way to defer that decision to later (the pause has to happen at
// kill time or not at all, matching the existing "send Pause immediately,
// optimistically" design elsewhere in this file). The underlying MediaRemote
// round trip is normally a fast, locally-cached lookup (nowplayingd), so a
// short cap here stays imperceptible; if it doesn't return in time, treat
// that as "don't know" rather than block the kill gesture indefinitely.
static pid_t KGGetNowPlayingPIDSync(void) {
    if (!gKGMRGetNowPlayingPID) return -1;
    dispatch_semaphore_t sem = dispatch_semaphore_create(0);
    __block int resultPID = -1;
    gKGMRGetNowPlayingPID(KGMediaRemoteReplyQueue(), ^(int pid) {
        resultPID = pid;
        dispatch_semaphore_signal(sem);
    });
    dispatch_semaphore_wait(sem, dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.15 * NSEC_PER_SEC)));
    return (pid_t)resultPID;
}

// container -> appLayout -> preferred UIWindowScene -> its underlying
// FBScene -> clientProcess -> pid looked correct (every hop responds to the
// selector chased) but was confirmed on-device (2026-09-23, via Frida) to
// always yield SpringBoard's OWN pid, for every container tried, regardless
// of the actual app being killed. Root cause: the switcher card's container
// class here is SBReusableSnapshotItemContainer -- a cached SNAPSHOT image
// of the app, not a live scene connection -- so _preferredWindowScene has
// no real per-app scene to hand back and appears to fall through to
// SpringBoard's own. Abandoned this path entirely rather than keep
// debugging an object graph that doesn't carry the information needed.
//
// Replacement: resolve bundle ID -> CFBundleExecutable (which
// KGDeriveArbitraryBundleID already gets reliably for the killed
// container) via a small on-disk scan, cached after first use since app
// installs rarely change mid-session, then compare that executable name
// against proc_name() of the Now Playing PID. Same "which real OS process
// is this" question, asked from data that's actually available instead of
// a scene-graph shortcut that silently wasn't wired the way it looked.
typedef int (*KGProcNameFn)(int pid, void *buf, uint32_t buffersize);

static KGProcNameFn KGProcNameSymbol(void) {
    static KGProcNameFn fn;
    static dispatch_once_t token;
    dispatch_once(&token, ^{
        fn = (KGProcNameFn)dlsym(RTLD_DEFAULT, "proc_name");
    });
    return fn;
}

static NSString *KGProcNameForPID(pid_t pid) {
    KGProcNameFn fn = KGProcNameSymbol();
    if (!fn || pid <= 0) return nil;
    char name[64] = {0};
    int len = fn(pid, name, sizeof(name));
    if (len <= 0) return nil;
    return [NSString stringWithUTF8String:name];
}

static NSMutableDictionary<NSString *, NSString *> *gKGBundleIDToExecutable = nil;

static void KGWarmBundleExecutableCache(void) {
    // Cheap enough to just scan everything once and cache the whole table,
    // rather than re-scanning per lookup -- both search roots together
    // (rootful device layout: user apps under Bundle/Application, a few
    // system-style test apps like BGBeacon under /Applications) are a few
    // hundred directories at most.
    gKGBundleIDToExecutable = [NSMutableDictionary dictionary];
    NSArray<NSString *> *searchDirs = @[@"/var/containers/Bundle/Application", @"/Applications"];
    NSFileManager *fm = [NSFileManager defaultManager];
    for (NSString *baseDir in searchDirs) {
        for (NSString *entry in [fm contentsOfDirectoryAtPath:baseDir error:nil]) {
            NSString *containerPath = [baseDir stringByAppendingPathComponent:entry];
            for (NSString *sub in [fm contentsOfDirectoryAtPath:containerPath error:nil]) {
                if (![sub hasSuffix:@".app"]) continue;
                NSString *infoPlistPath = [[containerPath stringByAppendingPathComponent:sub] stringByAppendingPathComponent:@"Info.plist"];
                NSDictionary *info = [NSDictionary dictionaryWithContentsOfFile:infoPlistPath];
                NSString *bid = info[@"CFBundleIdentifier"];
                NSString *exe = info[@"CFBundleExecutable"];
                if (bid && exe) gKGBundleIDToExecutable[bid] = exe;
            }
        }
    }
    KGWriteLog(@"WarmBundleExecutableCache: resolved %lu bundle(s)", (unsigned long)gKGBundleIDToExecutable.count);
}

static NSString *KGExecutableNameForBundleID(NSString *bundleID) {
    if (!gKGBundleIDToExecutable) KGWarmBundleExecutableCache();
    return gKGBundleIDToExecutable[bundleID];
}

// Same sysctl(KERN_PROC_ALL) scan JetsamBoostDaemon uses to resolve a bundle
// ID to its live PID -- reimplemented here rather than shared, since this
// file and that daemon don't share a build.
static pid_t KGFindPIDByProcessName(const char *name) {
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

// Protection only ever changes what happens on the NEXT backgrounding
// decision or kill attempt -- an app already running keeps whatever scene
// settings it already has until something re-triggers them. Killing it
// outright is the direct way to make it pick up the new config
// immediately.
//
// History (2026-09-23): tried detecting this automatically -- first via a
// Darwin notification AltList is supposed to post on change (fired
// unreliably), then a 2s poll timer with a per-app confirmation alert
// (the poll itself worked once its dispatch_source_t was fixed to be a
// static, not a local ARC-deallocated the moment the setup function
// returned, but the end-to-end experience was still reported as
// unstable/unpredictable). Replaced with an explicit "Apply" button in
// the picker's own navigation bar (see the ATLApplicationListMulti
// SelectionController hook below) -- the button press itself is the
// user's confirmation, so no separate alert is needed here.
static void KGKillRunningAppByBundleID(NSString *bundleID) {
    NSString *executable = KGExecutableNameForBundleID(bundleID);
    if (!executable) return;
    pid_t pid = KGFindPIDByProcessName([executable UTF8String]);
    if (pid <= 0) return;
    int result = kill(pid, SIGKILL);
    KGWriteLog(@"protection toggled for %@ (exe=%@) -- killed running pid=%d to apply immediately, result=%d",
               bundleID, executable, pid, result);
}

static void KGPauseImmediatelyOnKill(void) {
    if (!gKGMRSendCommand) return;
    Boolean sendResult = gKGMRSendCommand(kKGMRCommandPause, nil);
    KGWriteLog(@"kill requested -- sent immediate Pause, MRMediaRemoteSendCommand returned %d", sendResult);
}

// Only pause if the app actually being killed is the one actually making
// sound right now -- not just "some media-capable app," which was still
// wrong whenever a DIFFERENT watched app (e.g. Spotify) got killed while a
// different one (e.g. Music) was the one really playing (confirmed
// on-device 2026-09-23). A membership check in the watched catalog is kept
// as a cheap pre-filter so ordinary non-media apps skip the Now Playing
// round trip entirely; only a watched app pays that ~150ms-capped cost,
// and only ever to confirm -- never to expand -- whether it's the real
// target.
static void KGPauseIfKillingNowPlayingApp(NSString *killedBundleID, id container) {
    if (!killedBundleID || ![gKGWatchedApps containsObject:killedBundleID]) return;
    NSString *killedExecutable = KGExecutableNameForBundleID(killedBundleID);
    pid_t nowPlayingPID = KGGetNowPlayingPIDSync();
    NSString *nowPlayingExecutable = KGProcNameForPID(nowPlayingPID);
    if (killedExecutable && nowPlayingExecutable && [killedExecutable isEqualToString:nowPlayingExecutable]) {
        KGPauseImmediatelyOnKill();
    } else {
        KGWriteLog(@"kill requested for %@ (exe=%@) but Now Playing pid=%d (exe=%@) -- not the same app, skipping Pause",
                   killedBundleID, killedExecutable, nowPlayingPID, nowPlayingExecutable);
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

#pragma mark - Protection toggling

// A long-press-on-card toggle (with haptic-only feedback, no on-card
// visual) lived here through 2026-09-23. Three separate visual-badge
// approaches (a direct subview, an overlay window, a top-level switcher
// view badge) were all tried and confirmed broken on-device back on
// 2026-09-21, and shipping the toggle anyway with haptic-only feedback
// turned out not to actually work in practice either: with no visible
// confirmation of which apps are currently protected, the gesture was
// unusable (users can't tell whether a long-press did anything, or
// dependably tell current state, without opening Settings anyway) --
// removed rather than kept as a confusing, effectively-dead interaction.
// Protection is configured exclusively from Settings -> SwitcherGrid ->
// "Choose Protected Apps" (SGAppListController) now.

%group KillGuardHooks

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
        // KGPauseImmediatelyOnKill() used to fire unconditionally here for
        // ANY single-app swipe-kill, on the assumption that a swipe means
        // "the user wants this app's audio stopped." Confirmed on-device
        // (2026-09-23) that's wrong whenever the killed app has nothing to
        // do with audio: swiping away Filza or Settings while Music plays
        // paused Music too, since this call has no idea which app it's
        // even for -- it just blindly told MediaRemote to pause whatever
        // happens to be Now Playing. A first fix narrowed this to "only a
        // watched/media-capable app," but that was still wrong whenever the
        // watched app being killed wasn't the one actually playing (e.g.
        // killing Spotify while Music plays) -- confirmed on-device
        // 2026-09-23. KGPauseIfKillingNowPlayingApp additionally confirms
        // the killed app's own PID matches Now Playing's PID before pausing.
        KGRefreshConfigIfChanged();
        NSString *killedBundleID = KGDeriveArbitraryBundleID(container);
        KGPauseIfKillingNowPlayingApp(killedBundleID, container);
        %orig;
        return;
    }
    KGRefreshConfigIfChanged();
    NSString *bundleID = KGWatchedBundleIDInSwitcherContainer(container);
    if (bundleID) {
        KGWriteLog(@"BLOCKED killContainer:forReason: for %@ (reason=%ld)", bundleID, (long)reason);
        return;
    }
    // Same bug as the single-swipe branch above, just reached via kill-all's
    // per-container sweep instead: this container isn't a watched/media app
    // (those already returned via BLOCKED above), so it has nothing to do
    // with whatever's actually playing -- don't pause Now Playing just
    // because kill-all is tearing down an unrelated container.
    %orig;
}

%end

%end // KillGuardHooks

// An "Apply" button on AltList's own picker screen would need to run
// inside Preferences.app's process (that's where
// ATLApplicationListMultiSelectionController actually loads), not here --
// this file only ever runs inside SpringBoard. See
// Prefs/SGRootListController.m, which already runs in Preferences.app and
// already force-loads AltList.framework, for that half of this feature.

%ctor {
    if (strcmp(getprogname(), "SpringBoard") != 0) {
        return;
    }
    KGLoadConfig();
    KGResolveMediaRemoteSymbols();
    // Pre-warm off the main thread so the directory scan never adds latency
    // to an actual kill gesture -- the first swipe after a respring would
    // otherwise pay this cost synchronously inside killContainer:forReason:.
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        KGWarmBundleExecutableCache();
    });
    %init(KillGuardHooks);

    // Jetsam priority boost moved out to jetsamboostd (a separate root
    // LaunchDaemon, see ~/iOSTweaks/JetsamBoostDaemon) -- confirmed
    // on-device 2026-09-22 that memorystatus_control's priority-set command
    // requires root UID; SpringBoard runs as mobile and always got EPERM
    // here, silently, for every app ever tried (this file's old
    // KGBoostJetsamPriorityForWatchedApps/KGFindPIDByName never actually
    // worked despite years of no error logging to reveal that).

    KGWriteLog(@"KillGuard ctor loaded, protecting %lu app(s)", (unsigned long)gKGWatchedApps.count);
}
