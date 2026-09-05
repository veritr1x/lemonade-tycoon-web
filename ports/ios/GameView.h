#import <UIKit/UIKit.h>

@interface LemonView : UIView <UIKeyInput>
@property(nonatomic, strong) UIImage *frameImage;
@property(nonatomic) CGRect textRect;
@property(nonatomic) BOOL textActive;
@property(nonatomic) BOOL portraitPanels;
@property(nonatomic) BOOL preserveAspectRatio;
- (void)updateTextActive:(BOOL)active rect:(CGRect)rect;
- (void)cancelGameTouch;
@end
