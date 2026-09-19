// SwitcherGrid
// アプリスイッチャー(マルチタスク画面)をApple純正の「iPad風グリッドスタイル」で
// 表示させ、任意のカードを下スワイプすると表示中の全アプリを波状アニメーションで
// killできるようにするTweak。
//
// 実装の要点(実機調査で判明した事実):
// - iOS16のスイッチャーは自作のUICollectionViewLayoutではなく、物理演算(fluid)
//   ベースの独自レイアウトシステムで動いており、カード座標を自作するのは
//   非常に危険（SBFluidSwitcherViewControllerだけで600メソッド、非同期
//   completionを伴う内部ステートマシン）。
// - 一方でApple自身が「-[SBAppSwitcherSettings switcherStyle]」という
//   スタイル切り替えの仕組みを既に持っており(iPadの分割画面/グリッド表示等で
//   使われる値2 = グリッド)、これを強制するだけで安全にグリッド化できる。
//   これはOSS版NewGridSwitcher(iOS11-14向け)が使っていたのと同じ仕組みで、
//   iOS16.7.16でも生きていることを実機で確認済み。
// - 全kill機能は、Apple純正の単体kill(-[SBFluidSwitcherViewController
//   killContainer:forReason:]、reason=1)を、現在表示中の全カード
//   (-visibleItemContainers、NSDictionary)に対して少しずつ時間差(0.06秒刻み)で
//   呼び出すことで実現。個別killは常にApple純正のアニメーションを使うため、
//   自作の描画コードなしに「波状に崩れて消える」滑らかな見た目になる。

#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>

static NSString *const kPrefsPath = @"/var/mobile/Library/Preferences/com.mikiyan1978.switchergrid.plist";
static const NSInteger kGridStyleValue = 2; // Apple純正の「グリッドスタイル」に対応する値(実機調査で確認済み)

static BOOL gGridEnabled = YES;
static BOOL gKillAllSwipeEnabled = YES;

static void SGReloadPrefs(void) {
    NSDictionary *prefs = [NSDictionary dictionaryWithContentsOfFile:kPrefsPath];
    gGridEnabled = prefs[@"GridEnabled"] ? [prefs[@"GridEnabled"] boolValue] : YES;
    gKillAllSwipeEnabled = prefs[@"KillAllSwipeEnabled"] ? [prefs[@"KillAllSwipeEnabled"] boolValue] : YES;
}

%group SwitcherGridHooks

// グリッドスタイルの強制。無効時は元の挙動(Appleの自動判定)をそのまま通す。
%hook SBAppSwitcherSettings

- (NSInteger)switcherStyle {
    if (!gGridEnabled) return %orig;
    return kGridStyleValue;
}

- (NSInteger)effectiveSwitcherStyle {
    if (!gGridEnabled) return %orig;
    return kGridStyleValue;
}

- (void)setSwitcherStyle:(NSInteger)style {
    if (!gGridEnabled) {
        %orig;
        return;
    }
    %orig(kGridStyleValue);
}

%end

%hook SBFluidSwitcherViewController

- (void)viewDidLoad {
    %orig;
    UISwipeGestureRecognizer *killAllSwipe = [[UISwipeGestureRecognizer alloc] initWithTarget:self action:@selector(sg_handleKillAllSwipe:)];
    killAllSwipe.direction = UISwipeGestureRecognizerDirectionDown;
    killAllSwipe.delegate = (id<UIGestureRecognizerDelegate>)self;
    [((UIViewController *)self).view addGestureRecognizer:killAllSwipe];
}

// 既存のswitcher自身のドラッグ/パン系ジェスチャーと同時発火を許可しないと、
// UIKit標準の排他制御によりこちらが一切発火しない(実機で確認済み)。
%new
- (BOOL)gestureRecognizer:(UIGestureRecognizer *)gestureRecognizer shouldRecognizeSimultaneouslyWithGestureRecognizer:(UIGestureRecognizer *)otherGestureRecognizer {
    return YES;
}

// 下スワイプで、現在表示中の全カードを0.06秒刻みで順にkillしていく。
// 個別killはApple純正のアニメーション付き処理(reason=1、通常の上スワイプkillと同じ)を
// そのまま呼び出すため、自前で描画を書かなくても「波状に崩れて消える」滑らかな
// 見た目になる。
%new
- (void)sg_handleKillAllSwipe:(UISwipeGestureRecognizer *)gr {
    if (!gKillAllSwipeEnabled) return;
    if (gr.state != UIGestureRecognizerStateRecognized) return;

    NSDictionary *containers = ((NSDictionary * (*)(id, SEL))objc_msgSend)(self, @selector(visibleItemContainers));
    NSArray *snapshot = [containers.allValues copy];
    if (snapshot.count == 0) return;

    NSTimeInterval stagger = 0.06;
    void (*killIMP)(id, SEL, id, NSInteger) = (void (*)(id, SEL, id, NSInteger))objc_msgSend;
    SEL killSel = @selector(killContainer:forReason:);
    [snapshot enumerateObjectsUsingBlock:^(id container, NSUInteger idx, BOOL *stop) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)((double)idx * stagger * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            killIMP(self, killSel, container, 1);
        });
    }];
}

%end

%end // SwitcherGridHooks

static void SGPrefsChanged(CFNotificationCenterRef center, void *observer, CFStringRef name, const void *object, CFDictionaryRef userInfo) {
    SGReloadPrefs();
}

%ctor {
    SGReloadPrefs();
    CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(), NULL, SGPrefsChanged, CFSTR("com.mikiyan1978.switchergrid/reload"), NULL, CFNotificationSuspensionBehaviorDeliverImmediately);
    %init(SwitcherGridHooks);
}
