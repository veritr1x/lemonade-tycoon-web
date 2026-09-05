/* Simulator-only host integration check. This source is excluded from normal
 * builds and uses a separate bundle ID so it cannot change a player's saves. */
#import <UIKit/UIKit.h>
#import "../GameView.h"

@interface TestTouch : UITouch
@property(nonatomic) CGPoint point;
@end
@implementation TestTouch
- (CGPoint)locationInView:(UIView *)view {
  return self.point;
}
@end

static UIWindow *testWindow;
static LemonView *testGame;
static NSMutableArray *checks;
static void later(NSTimeInterval delay, void (^step)(void)) {
  dispatch_after(dispatch_time(DISPATCH_TIME_NOW, delay * NSEC_PER_SEC), dispatch_get_main_queue(),
                 step);
}
static void require(BOOL condition, NSString *label) {
  if (!condition) {
    fprintf(stderr, "FAIL: iOS smoke: %s\n", label.UTF8String);
    abort();
  }
  [checks addObject:label];
}
static CGPoint displayPoint(CGPoint guest, BOOL bottom) {
  CGRect display = [[testGame valueForKey:bottom ? @"bottomRect" : @"topRect"] CGRectValue];
  CGRect source = [[testGame valueForKey:bottom ? @"bottomSource" : @"topSource"] CGRectValue];
  return CGPointMake(
      display.origin.x + (guest.x - source.origin.x) * display.size.width / source.size.width,
      display.origin.y + (guest.y - source.origin.y) * display.size.height / source.size.height);
}
static void tap(CGPoint point, void (^next)(void)) {
  TestTouch *touch = [TestTouch new];
  touch.point = point;
  [testGame touchesBegan:[NSSet setWithObject:touch] withEvent:nil];
  later(.12, ^{
    [testGame touchesEnded:[NSSet setWithObject:touch] withEvent:nil];
    later(.5, next);
  });
}
static void capture(NSString *name) {
  UIGraphicsImageRenderer *renderer =
      [[UIGraphicsImageRenderer alloc] initWithSize:testWindow.bounds.size];
  UIImage *image = [renderer imageWithActions:^(UIGraphicsImageRendererContext *context) {
    [testWindow drawViewHierarchyInRect:testWindow.bounds afterScreenUpdates:YES];
  }];
  NSString *path =
      [NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES).firstObject
          stringByAppendingPathComponent:name];
  [UIImagePNGRepresentation(image) writeToFile:path atomically:YES];
}
static void checkHostControls(void) {
  UIViewController *controller = testWindow.rootViewController;
  UIButton *pause = [controller valueForKey:@"pauseButton"];
  [pause sendActionsForControlEvents:UIControlEventTouchUpInside];
  require(!testGame.userInteractionEnabled &&
              [pause.accessibilityLabel isEqualToString:@"Resume game"],
          @"Pause disables game input and exposes Resume");
  [pause sendActionsForControlEvents:UIControlEventTouchUpInside];
  require(testGame.userInteractionEnabled, @"Resume restores game input");
  UIButton *layout = [controller valueForKey:@"layoutButton"];
  [layout sendActionsForControlEvents:UIControlEventTouchUpInside];
  [testWindow layoutIfNeeded];
  require(!testGame.portraitPanels, @"Full-game comparison layout");
  [layout sendActionsForControlEvents:UIControlEventTouchUpInside];
  [testWindow layoutIfNeeded];
  require(testGame.portraitPanels, @"Portrait panels restored");
  capture(@"portrait-career.png");
  NSString *directory =
      NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES).firstObject;
  NSData *report =
      [NSJSONSerialization dataWithJSONObject:@{@"result" : @"passed", @"checks" : checks}
                                      options:NSJSONWritingPrettyPrinted
                                        error:nil];
  [report writeToFile:[directory stringByAppendingPathComponent:@"smoke.json"] atomically:YES];
  fprintf(stderr, "PASS: iOS portrait smoke checks (%lu); report in app Documents\n",
          (unsigned long)checks.count);
}
static void startChecks(void) {
  require(testGame.frameImage != nil, @"Original game renders");
  require(testGame.portraitPanels, @"Portrait panes active");
  UIStackView *toolbar = [testWindow.rootViewController valueForKey:@"toolbar"];
  require(toolbar.bounds.size.height <= 48.01, @"Portrait toolbar stays within one 48-point row");
  CGRect top = [[testGame valueForKey:@"topSource"] CGRectValue];
  CGRect bottom = [[testGame valueForKey:@"bottomSource"] CGRectValue];
  require(CGRectEqualToRect(top, CGRectMake(320, 0, 320, 480)),
          @"Top pane shows the complete right column");
  require(CGRectEqualToRect(bottom, CGRectMake(0, 0, 320, 480)),
          @"Bottom pane shows the complete left column");
  capture(@"portrait-menu.png");
  tap(displayPoint(CGPointMake(54, 198), YES), ^{
    tap(displayPoint(CGPointMake(72, 280), YES), ^{
      require(testGame.textActive && testGame.isFirstResponder,
              @"Career field opens keyboard through portrait input");
      [testGame insertText:@"PORTRAIT"];
      later(.5, ^{
        capture(@"portrait-keyboard.png");
        tap(CGPointMake(1, 1), ^{
          require(!testGame.isFirstResponder, @"Outside tap dismisses keyboard");
          tap(displayPoint(
                  CGPointMake(CGRectGetMidX(testGame.textRect), CGRectGetMidY(testGame.textRect)),
                  YES),
              ^{
                require(testGame.isFirstResponder, @"Bottom-pane field reopens keyboard");
                [testGame insertText:@"\n"];
                later(1, ^{
                  require(!testGame.textActive, @"Return creates career and closes the field");
                  // A drag ending outside must release the original button.
                  TestTouch *touch = [TestTouch new];
                  touch.point = displayPoint(CGPointMake(400, 150), NO);
                  [testGame touchesBegan:[NSSet setWithObject:touch] withEvent:nil];
                  CGPoint mapped = [[testGame valueForKey:@"lastGamePoint"] CGPointValue];
                  require(fabs(mapped.x - 400) < .01 && fabs(mapped.y - 150) < .01,
                          @"Top-pane touch reaches the original right column");
                  touch.point = CGPointMake(-100, -100);
                  [testGame touchesEnded:[NSSet setWithObject:touch] withEvent:nil];
                  require(![[testGame valueForKey:@"gameTouchDown"] boolValue],
                          @"Drag outside releases game touch");
                  checkHostControls();
                });
              });
        });
      });
    });
  });
}
void lemon_ios_smoke_test(UIWindow *window) {
  testWindow = window;
  testGame = [window.rootViewController valueForKey:@"game"];
  checks = [NSMutableArray new];
  [NSUserDefaults.standardUserDefaults setBool:NO forKey:@"classicLayout"];
  [window.rootViewController.view setNeedsLayout];
  later(5, ^{
    startChecks();
  });
}
