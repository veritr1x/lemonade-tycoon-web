/* Simulator-only host integration check. This source is excluded from normal
 * builds and uses a separate bundle ID so it cannot change a player's saves. */
#import <UIKit/UIKit.h>
#import "../GameView.h"
#import "../../../engine/game.h"
#import "../../../engine/save.h"
#import "../DashboardView.h"

@protocol LemonLayoutSelection
- (void)selectGameLayout:(NSInteger)mode;
- (void)resizePanes:(UIPanGestureRecognizer *)gesture;
@end

@interface TestTouch : UITouch
@property(nonatomic) CGPoint point;
@end
@implementation TestTouch
- (CGPoint)locationInView:(UIView *)view {
  return self.point;
}
@end

@interface TestPan : UIPanGestureRecognizer
@property(nonatomic) UIGestureRecognizerState testState;
@property(nonatomic) CGPoint delta;
@end
@implementation TestPan
- (UIGestureRecognizerState)state {
  return self.testState;
}
- (CGPoint)translationInView:(UIView *)view {
  return self.delta;
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
  [(id<LemonLayoutSelection>)controller selectGameLayout:2];
  [testWindow layoutIfNeeded];
  require(!testGame.portraitPanels && testGame.preserveAspectRatio,
          @"Original layout keeps the full game and its proportions");
  [(id<LemonLayoutSelection>)controller selectGameLayout:1];
  [testWindow layoutIfNeeded];
  require(testGame.portraitPanels && testGame.preserveAspectRatio,
          @"Keep proportions restores fitted portrait columns");
  [(id<LemonLayoutSelection>)controller selectGameLayout:0];
  [testWindow layoutIfNeeded];
  require(testGame.portraitPanels && !testGame.preserveAspectRatio,
          @"Fill screen restores expanded portrait columns");
  capture(@"portrait-career.png");
  CGRect gameFrame = testGame.frame;
  BOOL phone = controller.traitCollection.userInterfaceIdiom == UIUserInterfaceIdiomPhone;
  CGRect expectedFrame = phone ? CGRectInset(controller.view.safeAreaLayoutGuide.layoutFrame, 8, 8)
                               : controller.view.bounds;
  require(CGRectEqualToRect(gameFrame, expectedFrame),
          phone ? @"iPhone game keeps an 8-point border inside the safe area"
                : @"iPad game fills the screen behind the floating controls");
  UIButton *hide = [controller valueForKey:@"hideControlsButton"];
  UIButton *show = [controller valueForKey:@"showControlsButton"];
  UIStackView *toolbar = [controller valueForKey:@"toolbar"];
  [hide sendActionsForControlEvents:UIControlEventTouchUpInside];
  [testWindow layoutIfNeeded];
  require(toolbar.hidden && !show.hidden && CGRectEqualToRect(testGame.frame, gameFrame),
          @"Hide leaves a restore button without resizing the game");
  require([NSUserDefaults.standardUserDefaults boolForKey:@"controlsHidden"],
          @"Hidden controls preference is remembered");
  capture(@"fullscreen-controls-hidden.png");
  [show sendActionsForControlEvents:UIControlEventTouchUpInside];
  require(!toolbar.hidden && show.hidden &&
              ![NSUserDefaults.standardUserDefaults boolForKey:@"controlsHidden"],
          @"Restore brings back the floating toolbar");
  [(id<LemonLayoutSelection>)controller selectGameLayout:3];
  later(.6, ^{
    LemonDashboardView *dashboard = [controller valueForKey:@"dashboard"];
    require(!dashboard.hidden && testGame.hidden, @"Adaptive view opens");
    LemonView *street = [dashboard valueForKey:@"street"];
    CGRect source = [[street valueForKey:@"topSource"] CGRectValue];
    CGRect display = [[street valueForKey:@"topRect"] CGRectValue];
    require(fabs(source.size.width / source.size.height -
                 display.size.width / display.size.height) < .001,
            @"Adaptive street preserves artwork proportions");
    LemonView *original = testGame;
    testGame = [dashboard valueForKey:@"controls"];
    require(CGRectEqualToRect(testGame.sourceRect, CGRectMake(0, 0, 320, 480)),
            @"Adaptive includes the entire original controls column");
    CGRect controlsDisplay = [[testGame valueForKey:@"topRect"] CGRectValue];
    require(testGame.preserveAspectRatio &&
                fabs(controlsDisplay.size.width / controlsDisplay.size.height - 320.0 / 480) < .001,
            @"Adaptive controls preserve their original proportions");
    UIView *divider = [dashboard valueForKey:@"divider"];
    UIView *hud = [dashboard valueForKey:@"hud"];
    CGFloat span = dashboard.bounds.size.height - CGRectGetMaxY(hud.frame) - 16;
    require(fabs(testGame.frame.size.height / span - .52) < .001,
            @"Adaptive starts with the earlier balanced split");
    CGPoint grip = CGPointMake(CGRectGetMidX(divider.frame), CGRectGetMidY(divider.frame) - 20);
    require([dashboard hitTest:grip withEvent:nil] == divider,
            @"Divider has a 44-point hit area between the panes");
    TestTouch *held = [TestTouch new];
    held.point = displayPoint(CGPointMake(30, 15), NO);
    [testGame touchesBegan:[NSSet setWithObject:held] withEvent:nil];
    TestPan *pan = [TestPan new];
    pan.testState = UIGestureRecognizerStateBegan;
    [(id<LemonLayoutSelection>)dashboard resizePanes:pan];
    require(![[testGame valueForKey:@"gameTouchDown"] boolValue],
            @"Resizing releases held game input");
    pan.testState = UIGestureRecognizerStateChanged;
    pan.delta = CGPointMake(0, -span * .16);
    [(id<LemonLayoutSelection>)dashboard resizePanes:pan];
    CGRect enlarged = [[testGame valueForKey:@"topRect"] CGRectValue];
    require(enlarged.size.width > controlsDisplay.size.width * 1.2 &&
                fabs(enlarged.size.width / enlarged.size.height - 320.0 / 480) < .001,
            @"Divider drag resizes the controls live without stretching");
    pan.testState = UIGestureRecognizerStateEnded;
    [(id<LemonLayoutSelection>)dashboard resizePanes:pan];
    LemonDashboardView *restored =
        [[LemonDashboardView alloc] initWithFrame:CGRectMake(0, 0, 900, 400)];
    require(fabs([[restored valueForKey:@"portraitSplit"] doubleValue] - .68) < .001 &&
                fabs([[restored valueForKey:@"wideSplit"] doubleValue] - .48) < .001 &&
                testGame.userInteractionEnabled,
            @"Split persists and widescreen retains its own default");
    capture(@"adaptive-resized.png");
    tap(displayPoint(CGPointMake(257, 80), NO), ^{
      tap(displayPoint(CGPointMake(170, 244), NO), ^{
        capture(@"original-recipe.png");
        tap(displayPoint(CGPointMake(294, 80), NO), ^{
          tap(displayPoint(CGPointMake(50, 240), NO), ^{
            tap(displayPoint(CGPointMake(244, 284), NO), ^{
              tap(displayPoint(CGPointMake(280, 412), NO), ^{
                LemonGameState state;
                lemon_game_state(&state);
                require(state.modal_open && dashboard.hidden && !original.hidden,
                        @"Original purchase confirmation uses the full game view");
                testGame = original;
                tap(displayPoint(CGPointMake(440, 268), NO), ^{
                  LemonGameState bought;
                  lemon_game_state(&bought);
                  require(!bought.modal_open && bought.cash_cents == 3520 && !dashboard.hidden,
                          @"Original Supplies purchase works through Adaptive touch mapping");
                  [hide sendActionsForControlEvents:UIControlEventTouchUpInside];
                  testGame = [dashboard valueForKey:@"controls"];
                  [divider accessibilityActivate];
                  require(fabs(testGame.frame.size.height / span - .52) < .001,
                          @"Divider reset restores the default split");
                  [divider accessibilityIncrement];
                  require(fabs(testGame.frame.size.height / span - .545) < .001,
                          @"VoiceOver can adjust the split");
                  [divider accessibilityActivate];
                  capture(@"adaptive-career.png");
                  NSString *directory = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory,
                                                                            NSUserDomainMask, YES)
                                            .firstObject;
                  NSString *archive =
                      [directory stringByAppendingPathComponent:@"checkpoint.lemonade-save"];
                  require(lemon_save_export(directory.UTF8String, archive.UTF8String, 0) == 0 &&
                              lemon_save_validate(archive.UTF8String) == 0,
                          @"Original iOS checkpoint exports as a valid portable save");
                  NSData *report = [NSJSONSerialization
                      dataWithJSONObject:@{@"result" : @"passed", @"checks" : checks}
                                 options:NSJSONWritingPrettyPrinted
                                   error:nil];
                  [report writeToFile:[directory stringByAppendingPathComponent:@"smoke.json"]
                           atomically:YES];
                  fprintf(stderr,
                          "PASS: iOS portrait smoke checks (%lu); report in app Documents\n",
                          (unsigned long)checks.count);
                });
              });
            });
          });
        });
      });
    });
  });
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
  CGRect topDisplay = [[testGame valueForKey:@"topRect"] CGRectValue];
  CGRect bottomDisplay = [[testGame valueForKey:@"bottomRect"] CGRectValue];
  require(fabs(topDisplay.size.width - testGame.bounds.size.width) < .01 &&
              fabs(bottomDisplay.size.width - testGame.bounds.size.width) < .01,
          @"Fill screen uses the full width of both portrait panes");
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
  [NSUserDefaults.standardUserDefaults setBool:NO forKey:@"controlsHidden"];
  [NSUserDefaults.standardUserDefaults setInteger:0 forKey:@"gameLayout"];
  [window.rootViewController.view setNeedsLayout];
  later(5, ^{
    startChecks();
  });
}
