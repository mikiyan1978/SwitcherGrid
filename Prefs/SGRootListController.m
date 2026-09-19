#import "SGRootListController.h"

@implementation SGRootListController

// PSListControllerの既定実装は「クラス名.plist」を探すため、汎用PSListControllerを
// principalClassにしただけでは何も見つからず黒画面になっていた(実機で確認済み)。
// Root.plistを明示的に指定して読み込む。
- (NSArray *)specifiers {
    if (!_specifiers) {
        _specifiers = [self loadSpecifiersFromPlistName:@"Root" target:self];
    }
    return _specifiers;
}

@end
