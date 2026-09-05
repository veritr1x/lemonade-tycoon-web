#import <UIKit/UIKit.h>
#import "../../engine/game.h"
@interface LemonDashboardView : UIView
@property(nonatomic, strong) UIImage *frameImage;
- (void)refresh:(LemonGameState)state;
- (void)cancelGameTouch;
@end
