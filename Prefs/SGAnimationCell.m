#import "SGAnimationCell.h"

static NSString *const kPrefsPath = @"/var/mobile/Library/Preferences/com.mikiyan1978.switchergrid.plist";
static NSString *const kReloadNotification = @"com.mikiyan1978.switchergrid/reload";

static NSArray<NSString *> *SGAnimationTitles(void) {
    return @[@"フェード", @"ズーム", @"下からスライド", @"上からスライド", @"回転フェード"];
}

@implementation SGAnimationCell

// PSListControllerDefaultAppearanceProviderがカスタムcellClassの行をこの
// specifier付きイニシャライザ経由で生成する(SCPFormatCellと同じ理由で必須)。
- (instancetype)initWithStyle:(UITableViewCellStyle)style reuseIdentifier:(NSString *)reuseIdentifier specifier:(id)specifier {
    self = [super initWithStyle:UITableViewCellStyleValue1 reuseIdentifier:reuseIdentifier specifier:specifier];
    if (self) {
        self.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
        self.selectionStyle = UITableViewCellSelectionStyleDefault;
        self.textLabel.text = @"開くときのアニメーション";
        [self refreshDetail];
    }
    return self;
}

- (void)refreshCellContentsWithSpecifier:(id)specifier {
    [super refreshCellContentsWithSpecifier:specifier];
    [self refreshDetail];
}

- (void)refreshDetail {
    NSDictionary *prefs = [NSDictionary dictionaryWithContentsOfFile:kPrefsPath];
    NSInteger idx = prefs[@"TransitionStyle"] ? [prefs[@"TransitionStyle"] integerValue] : 0;
    NSArray *titles = SGAnimationTitles();
    self.detailTextLabel.text = (idx >= 0 && idx < (NSInteger)titles.count) ? titles[idx] : titles[0];
}

- (UIViewController *)sg_parentController {
    UIResponder *responder = self;
    while ((responder = [responder nextResponder])) {
        if ([responder isKindOfClass:[UIViewController class]]) return (UIViewController *)responder;
    }
    return nil;
}

- (void)setSelected:(BOOL)selected animated:(BOOL)animated {
    [super setSelected:NO animated:animated];
    if (!selected) return;

    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"開くときのアニメーション"
                                                                     message:nil
                                                              preferredStyle:UIAlertControllerStyleActionSheet];
    NSArray *titles = SGAnimationTitles();
    for (NSInteger i = 0; i < (NSInteger)titles.count; i++) {
        [alert addAction:[UIAlertAction actionWithTitle:titles[i]
                                                   style:UIAlertActionStyleDefault
                                                 handler:^(UIAlertAction *action) {
            NSMutableDictionary *prefs = [NSMutableDictionary dictionaryWithContentsOfFile:kPrefsPath] ?: [NSMutableDictionary dictionary];
            prefs[@"TransitionStyle"] = @(i);
            [prefs writeToFile:kPrefsPath atomically:YES];
            CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(),
                                                  (__bridge CFStringRef)kReloadNotification,
                                                  NULL, NULL, YES);
            [self refreshDetail];
        }]];
    }
    [alert addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];

    UIViewController *parent = [self sg_parentController];
    if (alert.popoverPresentationController) {
        alert.popoverPresentationController.sourceView = self;
        alert.popoverPresentationController.sourceRect = self.bounds;
    }
    [parent presentViewController:alert animated:YES completion:nil];
}

@end
