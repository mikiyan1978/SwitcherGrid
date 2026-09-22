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
// - SBFluidSwitcherViewControllerは生成時点のswitcherStyleを前提にレイアウトを
//   組むため、設定変更は既存インスタンスには反映されない(実機で確認済み)。
//   Eneko/StatusChameleonと同じ実績のある方式にならい、自動検知はせず、
//   設定画面の手動Respringボタンで反映させる。
// - 全kill機能は、Apple純正の単体kill(-[SBFluidSwitcherViewController
//   killContainer:forReason:]、reason=1)を、現在表示中の全カード
//   (-visibleItemContainers、NSDictionary)に対して少しずつ時間差で
//   呼び出すことで実現。個別killは常にApple純正のアニメーションを使うため、
//   自作の描画コードなしに「波状に崩れて消える」見た目になる。

#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>

static NSString *const kPrefsPath = @"/var/mobile/Library/Preferences/com.mikiyan1978.switchergrid.plist";
static const NSInteger kGridStyleValue = 2; // Apple純正の「グリッドスタイル」に対応する値(実機調査で確認済み)

static BOOL gGridEnabled = YES;
static BOOL gKillAllSwipeEnabled = YES;

// Shared with KillGuard.xm (same dylib): -[SBFluidSwitcherViewController
// killContainer:forReason:] is the SAME real Apple method a genuine
// single-app swipe-kill calls (confirmed on-device 2026-09-21 -- a plain
// swipe logged as "BLOCKED killContainer:forReason:" even after KillGuard
// was scoped to "kill-all only", because from that hook's point of view
// the two calls are indistinguishable). This flag is this file's own
// signal for "the call about to happen is specifically part of a kill-all
// sweep", set just before each staggered call and cleared right after, so
// KillGuard can tell them apart and leave a real single swipe alone.
BOOL gSGKillAllInProgress = NO;

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

// アプリが1つも無い状態でスイッチャーを開いた場合、瞬時にホーム画面へ戻す。
// handleHomeButtonPressはこのクラス自身が持つ、物理ホームボタン/ジェスチャーで
// 呼ばれるのと全く同じ「ホームに戻る」処理(実機のメソッド一覧で確認済み)。
// dispatch_afterで遅延させると効かず、%orig直後に同期的に呼ぶ必要があった
// (実機検証で確認済み)。
//
// 注記: 「開くときのアニメーション」機能はここに実装を試みたが、実機検証の
// 結果、通常のアプリ起動時にも同じviewDidAppearが(バックグラウンドで保持
// されている同一インスタンスの)裏方セッションとして発火することが判明し、
// アプリ起動時にアニメーションが誤発火する副作用が生じた。isKeyWindow等の
// 判定条件でも安全に区別できず、アプリ起動とswitcher表示が同一の
// viewDidAppearイベントを共有しているため、安全な実装方法が見つからな
// かった。そのため、この機能は撤去した。
- (void)viewDidAppear:(BOOL)animated {
    %orig;
    NSDictionary *containers = ((NSDictionary * (*)(id, SEL))objc_msgSend)(self, @selector(visibleItemContainers));
    if (containers.count > 0) return;
    SEL homeSel = @selector(handleHomeButtonPress);
    if ([(id)self respondsToSelector:homeSel]) {
        ((void (*)(id, SEL))objc_msgSend)(self, homeSel);
    }
}

// 下スワイプ/QuitAllスタイルのボタン、両方から使う共通の全kill処理。
// 個別killはApple純正のアニメーション付き処理(reason=1、通常の上スワイプkillと同じ)を
// そのまま呼び出すため、自前で描画を書かなくても「波状に崩れて消える」見た目になる。
// カード自体のframe/transformはswitcher内部の連続再レイアウトが常時上書きするため、
// 独自のUIViewアニメーションは効かない(実機で確認済み)。代わりに各killのタイミングに
// 合わせてハプティックを刻み、体感的な波を作る。
//
// バグ修正の経緯(2026-09-22, 実機報告): アプリ数が多いと全部killされず、しかも
// 「見えている分→少し遅れて残り」の2段階になるのが気になる、との指摘。
// 原因はどちらも同じ: -visibleItemContainersは名前通り「現在画面内に
// レイアウトされているカードのみ」を返す(スクロールでスイッチャー外に出ている
// カードにはそもそもコンテナが実体として存在しない -- 通常のセル再利用型UIと
// 同じ)。そのためコンテナ経由でしか全部を見つけられなかった。
//
// 修正: SBFluidSwitcherViewControllerには-appLayoutsという「画面外も含めた
// 全アプリのモデル(SBAppLayout配列)」を返すgetterが別に存在する(実機の
// メソッド一覧+型情報 @16@0:8 で確認済み)。これを使えば画面上のスクロール
// 状態に関係なく全件を1回で取得できる。コンテナが無いものは
// -_addVisibleItemContainerForAppLayout:reusingItemContainerIfExists:
// (型 v32@0:8@16@24、実機で確認済み)で強制的に生成してからkillする。
// これで発見に複数ラウンドかける必要がなくなり、全カードへ単一パスで
// 同時にkillContainer:forReason:を呼べる(=見た目も本当に一括になる)。
%new
- (void)sg_killAllContainers {
    id (*getAppLayoutsFn)(id, SEL) = (id (*)(id, SEL))objc_msgSend;
    NSArray *appLayouts = getAppLayoutsFn(self, @selector(appLayouts));
    if (appLayouts.count == 0) return;

    id (*getContainerFn)(id, SEL, id) = (id (*)(id, SEL, id))objc_msgSend;
    void (*addContainerFn)(id, SEL, id, id) = (void (*)(id, SEL, id, id))objc_msgSend;
    SEL getContainerSel = @selector(_itemContainerForAppLayoutIfExists:);
    SEL addContainerSel = @selector(_addVisibleItemContainerForAppLayout:reusingItemContainerIfExists:);

    NSMutableArray *containersToKill = [NSMutableArray arrayWithCapacity:appLayouts.count];
    for (id appLayout in appLayouts) {
        id container = getContainerFn(self, getContainerSel, appLayout);
        if (!container) {
            addContainerFn(self, addContainerSel, appLayout, nil);
            container = getContainerFn(self, getContainerSel, appLayout);
        }
        if (container) {
            [containersToKill addObject:container];
        }
    }

    UIImpactFeedbackGenerator *haptic = [[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleMedium];
    [haptic prepare];
    [haptic impactOccurred];

    void (*killIMP)(id, SEL, id, NSInteger) = (void (*)(id, SEL, id, NSInteger))objc_msgSend;
    SEL killSel = @selector(killContainer:forReason:);
    gSGKillAllInProgress = YES;
    for (id container in containersToKill) {
        killIMP(self, killSel, container, 1);
    }
    gSGKillAllInProgress = NO;
}

%new
- (void)sg_handleKillAllSwipe:(UISwipeGestureRecognizer *)gr {
    if (!gKillAllSwipeEnabled) return;
    if (gr.state != UIGestureRecognizerStateRecognized) return;
    ((void (*)(id, SEL))objc_msgSend)(self, @selector(sg_killAllContainers));
}

%end

// QuitAll(https://github.com/vanwijkdave/QuitAll)を参考にした、常時表示の
// 「Clear」ボタン方式。QuitAllは古いiOS向けにSBMainSwitcherViewController/
// SBAppSwitcherScrollViewを対象にしていたが、この端末(iOS16.7.16)では
// SBAppSwitcherScrollView自体は実在を確認済み。ボタンからは
// nextResponderを辿って所有元のSBFluidSwitcherViewControllerを見つけ、
// 上のsg_killAllContainersをそのまま呼び出す。
%hook SBAppSwitcherScrollView

- (void)didMoveToWindow {
    %orig;
    if (!gKillAllSwipeEnabled) return;
    UIScrollView *scrollView = (UIScrollView *)self;
    if (scrollView.window == nil) return;
    if (objc_getAssociatedObject(self, @selector(sg_clearButtonContainer))) return;

    UIView *container = [[UIView alloc] init];
    container.clipsToBounds = YES;
    container.layer.cornerRadius = 14;
    container.translatesAutoresizingMaskIntoConstraints = NO;

    UIBlurEffect *blur = [UIBlurEffect effectWithStyle:UIBlurEffectStyleSystemThinMaterial];
    UIVisualEffectView *blurView = [[UIVisualEffectView alloc] initWithEffect:blur];
    blurView.frame = container.bounds;
    blurView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    [container addSubview:blurView];

    UILabel *label = [UILabel new];
    label.text = @"すべて閉じる";
    label.font = [UIFont boldSystemFontOfSize:13];
    label.textColor = [UIColor whiteColor];
    label.textAlignment = NSTextAlignmentCenter;
    label.userInteractionEnabled = NO;
    label.translatesAutoresizingMaskIntoConstraints = NO;
    [container addSubview:label];
    [NSLayoutConstraint activateConstraints:@[
        [label.centerXAnchor constraintEqualToAnchor:container.centerXAnchor],
        [label.centerYAnchor constraintEqualToAnchor:container.centerYAnchor],
    ]];

    UIButton *button = [UIButton buttonWithType:UIButtonTypeCustom];
    button.translatesAutoresizingMaskIntoConstraints = NO;
    [button addTarget:self action:@selector(sg_clearButtonTapped:) forControlEvents:UIControlEventTouchUpInside];
    [container addSubview:button];
    [NSLayoutConstraint activateConstraints:@[
        [button.topAnchor constraintEqualToAnchor:container.topAnchor],
        [button.bottomAnchor constraintEqualToAnchor:container.bottomAnchor],
        [button.leadingAnchor constraintEqualToAnchor:container.leadingAnchor],
        [button.trailingAnchor constraintEqualToAnchor:container.trailingAnchor],
    ]];

    UIView *superview = scrollView.superview ?: scrollView;
    [superview addSubview:container];
    [NSLayoutConstraint activateConstraints:@[
        [container.topAnchor constraintEqualToAnchor:superview.safeAreaLayoutGuide.topAnchor constant:12],
        [container.trailingAnchor constraintEqualToAnchor:superview.trailingAnchor constant:-18],
        [container.widthAnchor constraintEqualToConstant:96],
        [container.heightAnchor constraintEqualToConstant:32],
    ]];

    // 登場アニメーション: フェード+スケールでポップインさせる(QuitAllは単純な
    // フェードのみだったため、そこを拡張)。
    container.alpha = 0.0;
    container.transform = CGAffineTransformMakeScale(0.7, 0.7);
    [UIView animateWithDuration:0.4 delay:0.15 usingSpringWithDamping:0.6 initialSpringVelocity:0 options:0 animations:^{
        container.alpha = 1.0;
        container.transform = CGAffineTransformIdentity;
    } completion:nil];

    objc_setAssociatedObject(self, @selector(sg_clearButtonContainer), container, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

// QuitAllと同じ仕組み: スイッチャーが再表示されてスクロールが有効になるたび
// (setScrollEnabled:YES)、tapで隠したボタンを再度フェードインさせる。これが
// ないと、一度tapした後は二度とボタンが出てこない(実機で確認済み)。
- (void)setScrollEnabled:(BOOL)enabled {
    %orig;
    UIView *container = objc_getAssociatedObject(self, @selector(sg_clearButtonContainer));
    if (!container) return;
    [UIView animateWithDuration:0.3 animations:^{
        container.alpha = enabled ? 1.0 : 0.0;
    }];
}

%new
- (void)sg_clearButtonTapped:(UIButton *)sender {
    UIResponder *responder = (UIResponder *)self;
    Class fluidClass = NSClassFromString(@"SBFluidSwitcherViewController");
    while ((responder = [responder nextResponder])) {
        if (fluidClass && [responder isKindOfClass:fluidClass]) {
            ((void (*)(id, SEL))objc_msgSend)(responder, @selector(sg_killAllContainers));
            break;
        }
    }
    UIView *container = objc_getAssociatedObject(self, @selector(sg_clearButtonContainer));
    [UIView animateWithDuration:0.2 animations:^{
        container.alpha = 0.0;
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
