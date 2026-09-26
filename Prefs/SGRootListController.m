#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <spawn.h>
#import <objc/message.h>
#import <objc/runtime.h>
#import <dlfcn.h>
#import "SGRootListController.h"

// /Library/PreferenceBundles/AltList.bundle is a symlink straight to
// AltList.framework (not a real .bundle wrapper). PreferenceLoader's bundle
// scan does not dlopen it on this iOS build, so
// ATLApplicationListMultiSelectionController is never registered in
// Preferences.app's runtime -- confirmed via NSClassFromString returning nil
// at the point our own PSLinkListCell row tries to push it (hence the black
// screen: PSListController silently no-ops pushing a nil detail class).
// Force-load the framework ourselves before anything references its classes.
//
// Second bug, same root file StayForeground's SFRootListController.m
// documents in full: popping an AltList detail controller crashes with
// EXC_BAD_ACCESS/SIGBUS inside -[PSListController clearCache] during the
// delayed post-pop dealloc, on this iOS build's Preferences.framework.
// Workaround: no-op clearCache for AltList's own controller classes (it only
// clears icon caches, so this is a harmless leak, not a functional loss).
static void (*gSGOrigClearCache)(id, SEL);
static void SGClearCacheNoOp(id self, SEL _cmd) {
    if ([self isKindOfClass:NSClassFromString(@"ATLApplicationListControllerBase")]) {
        return;
    }
    if (gSGOrigClearCache) gSGOrigClearCache(self, _cmd);
}

// "Apply" button on AltList's own protected-apps picker (pushed from this
// Prefs bundle's own screen, so this file -- which already runs inside
// Preferences.app's process -- is the right place for it, not KillGuard.xm,
// which only ever runs inside SpringBoard and never sees this view
// controller class at all).
//
// History (2026-09-23): tried applying a protection change immediately
// without a full respring -- first automatically (a Darwin notification
// AltList is supposed to post on change fired unreliably; a poll-timer
// variant, even once its own dispatch_source_t retention bug was fixed,
// still felt unstable/unpredictable end to end), then via this same button
// killing only the specific apps whose protection changed. Simplified to a
// full respring instead: blunt, but completely unambiguous -- every app
// picks up the current ProtectedBundleIDs catalog fresh, guaranteed, the
// same way any other config change in this project already required a
// manual respring to apply (see sg_respringTapped's own comment). Reuses
// that exact mechanism (SCPowerKit's respring if installed, sbreload
// fallback otherwise) rather than duplicating it.
static void SGApplyProtectionChangesNow(id self, SEL _cmd) {
    Class powerKitClass = NSClassFromString(@"SCPowerKit");
    SEL respringSel = @selector(respring);
    if (powerKitClass && [powerKitClass respondsToSelector:respringSel]) {
        ((void (*)(id, SEL))objc_msgSend)(powerKitClass, respringSel);
        return;
    }
    pid_t pid;
    char *args[] = {"/usr/bin/sbreload", NULL};
    posix_spawn(&pid, "/usr/bin/sbreload", NULL, NULL, args, NULL);
}

static void (*gSGOrigALMSCViewDidLoad)(id, SEL);
static void SGALMSCViewDidLoad(id self, SEL _cmd) {
    if (gSGOrigALMSCViewDidLoad) gSGOrigALMSCViewDidLoad(self, _cmd);
    UIViewController *vc = self;
    vc.navigationItem.rightBarButtonItem =
        [[UIBarButtonItem alloc] initWithTitle:@"Apply"
                                          style:UIBarButtonItemStyleDone
                                         target:vc
                                         action:@selector(sg_applyProtectionChangesTapped)];
}

@interface NSObject (SGApplyProtectionChangesButton)
- (void)sg_applyProtectionChangesTapped;
@end

__attribute__((constructor))
static void SGLoadAltListFramework(void) {
    dlopen("/Library/Frameworks/AltList.framework/AltList", RTLD_NOW);

    Class listControllerCls = NSClassFromString(@"PSListController");
    SEL clearCacheSel = @selector(clearCache);
    Method m = listControllerCls ? class_getInstanceMethod(listControllerCls, clearCacheSel) : NULL;
    if (m) {
        gSGOrigClearCache = (void (*)(id, SEL))method_getImplementation(m);
        method_setImplementation(m, (IMP)SGClearCacheNoOp);
    }

    Class multiSelectCls = NSClassFromString(@"ATLApplicationListMultiSelectionController");
    SEL viewDidLoadSel = @selector(viewDidLoad);
    Method vdlMethod = multiSelectCls ? class_getInstanceMethod(multiSelectCls, viewDidLoadSel) : NULL;
    if (vdlMethod) {
        gSGOrigALMSCViewDidLoad = (void (*)(id, SEL))method_getImplementation(vdlMethod);
        method_setImplementation(vdlMethod, (IMP)SGALMSCViewDidLoad);
        // sg_applyProtectionChangesTapped itself is added as a real method
        // (not just referenced via performSelector) so the button's target/
        // action wiring above works the normal Cocoa way.
        class_addMethod(multiSelectCls, @selector(sg_applyProtectionChangesTapped),
                         (IMP)SGApplyProtectionChangesNow, "v@:");
    }
}

@implementation SGRootListController

- (NSArray *)specifiers {
    if (!_specifiers) {
        _specifiers = [self loadSpecifiersFromPlistName:@"Root" target:self];
    }
    return _specifiers;
}

// StatusChameleonと同じ実績のあるパターン。設定変更はライブに書き込まれるが、
// アプリスイッチャーのスタイルはSBFluidSwitcherViewControllerが生成時点の値を
// 前提にしているため、反映には手動リスプリングが必要(実機検証で確認済み)。
- (void)sg_respringTapped {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Respring?"
                                                                     message:@"This will briefly close all apps and restart the Home Screen."
                                                              preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
    [alert addAction:[UIAlertAction actionWithTitle:@"Respring" style:UIAlertActionStyleDestructive handler:^(UIAlertAction *action) {
        // 共有ライブラリlibpowerkit(SCPowerKit)がインストール済みならそちらの
        // respringを使う(他Tweakとロジックを重複させない、という方針のため)。
        // 未インストールの環境でも動くよう、performSelectorで疎結合に呼び、
        // クラスが無ければ従来通りsbreloadに直接フォールバックする。
        Class powerKitClass = NSClassFromString(@"SCPowerKit");
        SEL respringSel = @selector(respring);
        if (powerKitClass && [powerKitClass respondsToSelector:respringSel]) {
            ((void (*)(id, SEL))objc_msgSend)(powerKitClass, respringSel);
            return;
        }
        pid_t pid;
        char *args[] = {"/usr/bin/sbreload", NULL};
        posix_spawn(&pid, "/usr/bin/sbreload", NULL, NULL, args, NULL);
    }]];
    [self presentViewController:alert animated:YES completion:nil];
}

@end
