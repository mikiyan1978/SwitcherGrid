#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <spawn.h>
#import <objc/message.h>
#import "SGRootListController.h"

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
