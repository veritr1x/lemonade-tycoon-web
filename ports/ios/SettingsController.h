#import <UIKit/UIKit.h>
@interface LemonSettingsController : UIViewController
@property(nonatomic, copy) BOOL (^isGameRunning)(void);
@property(nonatomic, copy) void (^closeGame)(void);
@end
