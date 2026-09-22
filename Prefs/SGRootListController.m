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
