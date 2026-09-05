#import <UIKit/UIKit.h>
#import <AVFoundation/AVFoundation.h>
#import "../../engine/audio.h"
#import "../../engine/platform.h"
#import "GameView.h"

typedef NS_ENUM(NSInteger, LemonLayoutMode) {
  LemonLayoutFill,
  LemonLayoutFit,
  LemonLayoutOriginal,
};

// UIKit and AVAudioEngine state is confined to the main thread.
static AVAudioEngine *audioEngine;
static BOOL audioRequested, audioInterrupted, appActive = YES, userPaused, userMuted;
static NSLock *frameLock;
static NSData *pendingFrame;
static BOOL frameDeliveryQueued;

static BOOL hostActive(void) { return appActive && !audioInterrupted && !userPaused; }
static BOOL resumeAudio(void) {
  if (!audioRequested || !hostActive())
    return YES;
  if (audioEngine.isRunning)
    return YES;
  NSError *error = nil;
  AVAudioSession *session = AVAudioSession.sharedInstance;
  if (![session setCategory:AVAudioSessionCategoryAmbient error:&error] ||
      ![session setActive:YES error:&error]) {
    fprintf(stderr, "Apple audio session: %s\n", error.description.UTF8String);
    return NO;
  }
  if (!audioEngine) {
    audioEngine = [AVAudioEngine new];
    AVAudioFormat *format = [[AVAudioFormat alloc] initStandardFormatWithSampleRate:44100
                                                                           channels:2];
    __block BOOL reportedPCM = NO;
    AVAudioSourceNode *source = [[AVAudioSourceNode alloc]
        initWithFormat:format
           renderBlock:^OSStatus(BOOL *silence, const AudioTimeStamp *time,
                                 AVAudioFrameCount frames, AudioBufferList *buffers) {
             if (buffers->mNumberBuffers != 2)
               return -1;
             lemon_audio_render(buffers->mBuffers[0].mData, buffers->mBuffers[1].mData, frames,
                                44100);
             *silence = NO;
             if (!reportedPCM) {
               float *left = buffers->mBuffers[0].mData;
               for (unsigned i = 0; i < frames; i++)
                 if (left[i] != 0) {
                   reportedPCM = YES;
                   dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
                     fprintf(stderr, "Apple audio render: nonzero game PCM delivered\n");
                   });
                   break;
                 }
             }
             return noErr;
           }];
    [audioEngine attachNode:source];
    [audioEngine connect:source to:audioEngine.mainMixerNode format:format];
  }
  audioEngine.mainMixerNode.outputVolume = userMuted ? 0 : 1;
  BOOL ok = [audioEngine startAndReturnError:&error];
  fprintf(stderr, "Apple audio engine: %s\n", ok ? "running" : error.description.UTF8String);
  return ok;
}
int lemon_audio_start(void) {
  __block BOOL result;
  void (^start)(void) = ^{
    audioRequested = YES;
    result = resumeAudio();
  };
  if (NSThread.isMainThread)
    start();
  else
    dispatch_sync(dispatch_get_main_queue(), start);
  return result;
}
void lemon_audio_stop(void) {
  void (^stop)(void) = ^{
    audioRequested = NO;
    [audioEngine stop];
    audioEngine = nil;
  };
  if (NSThread.isMainThread)
    stop();
  else
    dispatch_sync(dispatch_get_main_queue(), stop);
}

@interface LemonController : UIViewController
@property(nonatomic, strong) LemonView *game;
@property(nonatomic, strong) UILabel *status;
@property(nonatomic, strong) UIButton *restart;
@property(nonatomic) BOOL running;
@property(nonatomic, strong) UIStackView *toolbar;
@property(nonatomic, strong) UIButton *pauseButton, *soundButton, *layoutButton;
@property(nonatomic, strong) NSArray<NSLayoutConstraint *> *portraitConstraints, *wideConstraints;
- (void)refreshHostActivity;
@end
static __weak LemonController *controller;
static int openGameURL(const char *address) {
  // The game runs on a worker thread; UIKit completes the handoff on the main thread.
  @autoreleasepool {
    NSURL *url = [NSURL URLWithString:@(address)];
    NSString *scheme = url.scheme.lowercaseString;
    if (!url.host.length ||
        (![scheme isEqualToString:@"http"] && ![scheme isEqualToString:@"https"]))
      return 0;
    dispatch_semaphore_t done = dispatch_semaphore_create(0);
    __block BOOL opened = NO;
    dispatch_async(dispatch_get_main_queue(), ^{
      [UIApplication.sharedApplication openURL:url
          options:@{}
          completionHandler:^(BOOL success) {
            opened = success;
            dispatch_semaphore_signal(done);
          }];
    });
    dispatch_semaphore_wait(done, DISPATCH_TIME_FOREVER);
    return opened;
  }
}
static void presentKeyboard(int visible, int x, int y, int width, int height) {
  dispatch_async(dispatch_get_main_queue(), ^{
    [controller.game updateTextActive:visible rect:CGRectMake(x, y, width, height)];
  });
}
static void presentFrame(const uint32_t *rgb, unsigned width, unsigned height) {
  if (width != 640 || height != 480)
    return;
  @autoreleasepool {
    // At most one pending main-thread delivery. Replace stale pixels instead of
    // letting slow layout, rotation, or accessibility build an unbounded queue.
    NSData *data = [NSData dataWithBytes:rgb length:width * height * 4];
    [frameLock lock];
    pendingFrame = data;
    BOOL schedule = !frameDeliveryQueued;
    frameDeliveryQueued = YES;
    [frameLock unlock];
    if (!schedule)
      return;
    dispatch_async(dispatch_get_main_queue(), ^{
      [frameLock lock];
      NSData *latest = pendingFrame;
      pendingFrame = nil;
      frameDeliveryQueued = NO;
      [frameLock unlock];
      if (!controller.running || !latest)
        return;
      CGDataProviderRef provider = CGDataProviderCreateWithCFData((__bridge CFDataRef)latest);
      CGColorSpaceRef colors = CGColorSpaceCreateDeviceRGB();
      CGImageRef cg = CGImageCreate(640, 480, 8, 32, 640 * 4, colors,
                                    kCGBitmapByteOrder32Little | kCGImageAlphaNoneSkipFirst,
                                    provider, NULL, NO, kCGRenderingIntentDefault);
      controller.game.frameImage = [UIImage imageWithCGImage:cg];
      CGImageRelease(cg);
      CGColorSpaceRelease(colors);
      CGDataProviderRelease(provider);
      controller.status.hidden = YES;
    });
  }
}
static int presentDialog(const char *title, const char *body, int trial, char *name, char *code) {
  // Preserve the shared dialog callback contract; standalone builds skip trial dialogs.
  @autoreleasepool {
    dispatch_semaphore_t done = dispatch_semaphore_create(0);
    __block int result = 2;
    NSString *t = @(title), *b = @(body);
    dispatch_async(dispatch_get_main_queue(), ^{
      UIAlertController *a =
          [UIAlertController alertControllerWithTitle:t
                                              message:b
                                       preferredStyle:UIAlertControllerStyleAlert];
      if (trial >= 0) {
        [a addTextFieldWithConfigurationHandler:^(UITextField *f) {
          f.placeholder = @"License Name";
          f.autocorrectionType = UITextAutocorrectionTypeNo;
        }];
        [a addTextFieldWithConfigurationHandler:^(UITextField *f) {
          f.placeholder = @"License Code";
          f.autocorrectionType = UITextAutocorrectionTypeNo;
          f.autocapitalizationType = UITextAutocapitalizationTypeNone;
        }];
        [a addAction:[UIAlertAction
                         actionWithTitle:@"Register"
                                   style:UIAlertActionStyleDefault
                                 handler:^(UIAlertAction *x) {
                                   snprintf(name, 1024, "%s", a.textFields[0].text.UTF8String);
                                   snprintf(code, 1024, "%s", a.textFields[1].text.UTF8String);
                                   result = 1003;
                                   dispatch_semaphore_signal(done);
                                 }]];
        if (trial)
          [a addAction:[UIAlertAction actionWithTitle:@"Try Now"
                                                style:UIAlertActionStyleDefault
                                              handler:^(UIAlertAction *x) {
                                                result = 1005;
                                                dispatch_semaphore_signal(done);
                                              }]];
      }
      [a addAction:[UIAlertAction actionWithTitle:trial < 0 ? @"OK" : @"Cancel"
                                            style:UIAlertActionStyleCancel
                                          handler:^(UIAlertAction *x) {
                                            dispatch_semaphore_signal(done);
                                          }]];
      [controller presentViewController:a animated:YES completion:nil];
    });
    dispatch_semaphore_wait(done, DISPATCH_TIME_FOREVER);
    return result;
  }
}
@implementation LemonController
- (UIButton *)button:(NSString *)symbol label:(NSString *)label action:(SEL)action {
  UIButton *button = [UIButton buttonWithType:UIButtonTypeSystem];
  UIButtonConfiguration *style = [UIButtonConfiguration tintedButtonConfiguration];
  style.image = [UIImage systemImageNamed:symbol];
  // Explicit symbol size keeps the artwork inside its 48-point touch target,
  // including at the largest accessibility text size.
  style.preferredSymbolConfigurationForImage =
      [UIImageSymbolConfiguration configurationWithPointSize:24 weight:UIImageSymbolWeightRegular];
  style.baseForegroundColor = [UIColor colorWithRed:1 green:.87 blue:.28 alpha:1];
  button.configuration = style;
  button.accessibilityLabel = label;
  button.toolTip = label;
  [button.widthAnchor constraintEqualToConstant:48].active = YES;
  NSLayoutConstraint *height = [button.heightAnchor constraintGreaterThanOrEqualToConstant:48];
  height.active = YES;
  if (action)
    [button addTarget:self action:action forControlEvents:UIControlEventTouchUpInside];
  return button;
}
- (void)refreshHostActivity {
  lemon_set_active(hostActive());
  if (hostActive())
    resumeAudio();
  else
    [audioEngine pause];
  self.game.userInteractionEnabled = self.running && !userPaused;
  self.pauseButton.accessibilityLabel = userPaused ? @"Resume game" : @"Pause game";
  self.pauseButton.toolTip = self.pauseButton.accessibilityLabel;
  UIButtonConfiguration *style = self.pauseButton.configuration;
  style.image = [UIImage systemImageNamed:userPaused ? @"play.fill" : @"pause.fill"];
  self.pauseButton.configuration = style;
}
- (void)togglePause {
  [self.game cancelGameTouch];
  [self.game resignFirstResponder];
  userPaused = !userPaused;
  [self refreshHostActivity];
  UIAccessibilityPostNotification(UIAccessibilityAnnouncementNotification,
                                  userPaused ? @"Game paused" : @"Game resumed");
}
- (void)toggleSound {
  [self.game resignFirstResponder];
  userMuted = !userMuted;
  [NSUserDefaults.standardUserDefaults setBool:userMuted forKey:@"soundMuted"];
  audioEngine.mainMixerNode.outputVolume = userMuted ? 0 : 1;
  UIButtonConfiguration *style = self.soundButton.configuration;
  style.image =
      [UIImage systemImageNamed:userMuted ? @"speaker.slash.fill" : @"speaker.wave.2.fill"];
  self.soundButton.configuration = style;
  self.soundButton.accessibilityLabel = userMuted ? @"Unmute sound" : @"Mute sound";
  self.soundButton.toolTip = self.soundButton.accessibilityLabel;
}
- (LemonLayoutMode)gameLayoutMode {
  NSInteger mode = [NSUserDefaults.standardUserDefaults integerForKey:@"gameLayout"];
  return mode >= LemonLayoutFill && mode <= LemonLayoutOriginal ? mode : LemonLayoutFill;
}
- (void)selectGameLayout:(LemonLayoutMode)mode {
  [self.game cancelGameTouch];
  [self.game resignFirstResponder];
  [NSUserDefaults.standardUserDefaults setInteger:mode forKey:@"gameLayout"];
  [self updateLayoutMenu];
  [self.view setNeedsLayout];
  UIAccessibilityPostNotification(UIAccessibilityAnnouncementNotification,
                                  self.layoutButton.accessibilityValue);
}
- (void)updateLayoutMenu {
  NSArray<NSString *> *titles = @[ @"Fill screen", @"Keep proportions", @"Original layout" ];
  NSMutableArray<UIAction *> *actions = [NSMutableArray new];
  LemonLayoutMode selected = [self gameLayoutMode];
  __weak LemonController *weakSelf = self;
  for (LemonLayoutMode mode = LemonLayoutFill; mode <= LemonLayoutOriginal; mode++) {
    UIAction *action = [UIAction actionWithTitle:titles[mode]
                                           image:nil
                                      identifier:nil
                                         handler:^(UIAction *sender) {
                                           [weakSelf selectGameLayout:mode];
                                         }];
    action.state = mode == selected ? UIMenuElementStateOn : UIMenuElementStateOff;
    [actions addObject:action];
  }
  self.layoutButton.menu = [UIMenu menuWithTitle:@"" children:actions];
  self.layoutButton.accessibilityValue = titles[selected];
}
- (void)viewWillLayoutSubviews {
  [super viewWillLayoutSubviews];
  [self updateGameLayout];
}
- (void)updateGameLayout {
  BOOL wide = self.view.bounds.size.width > self.view.bounds.size.height;
  NSArray *active = wide ? self.wideConstraints : self.portraitConstraints;
  NSArray *inactive = wide ? self.portraitConstraints : self.wideConstraints;
  if (!((NSLayoutConstraint *)active.firstObject).active) {
    [NSLayoutConstraint deactivateConstraints:inactive];
    // No title or text-size-dependent header competes with the game. Portrait
    // gets one compact row; widescreen gets a narrow rail beside the full frame.
    self.toolbar.axis = wide ? UILayoutConstraintAxisVertical : UILayoutConstraintAxisHorizontal;
    self.toolbar.spacing = wide ? 4 : 8;
    [NSLayoutConstraint activateConstraints:active];
  }
  LemonLayoutMode mode = [self gameLayoutMode];
  BOOL panels = !wide && mode != LemonLayoutOriginal;
  if (self.game.portraitPanels != panels)
    self.game.portraitPanels = panels;
  BOOL preserve = mode != LemonLayoutFill;
  if (self.game.preserveAspectRatio != preserve)
    self.game.preserveAspectRatio = preserve;
}
- (void)viewDidLoad {
  [super viewDidLoad];
  controller = self;
  self.overrideUserInterfaceStyle = UIUserInterfaceStyleDark;
  self.view.backgroundColor = UIColor.blackColor;
  self.game = [[LemonView alloc] initWithFrame:self.view.bounds];
  self.game.translatesAutoresizingMaskIntoConstraints = NO;
  [self.view addSubview:self.game];
  self.soundButton = [self button:userMuted ? @"speaker.slash.fill" : @"speaker.wave.2.fill"
                            label:userMuted ? @"Unmute sound" : @"Mute sound"
                           action:@selector(toggleSound)];
  self.pauseButton = [self button:@"pause.fill" label:@"Pause game" action:@selector(togglePause)];
  self.layoutButton = [self button:@"rectangle.split.1x2" label:@"Game layout" action:NULL];
  self.layoutButton.showsMenuAsPrimaryAction = YES;
  [self updateLayoutMenu];
  self.toolbar = [[UIStackView alloc]
      initWithArrangedSubviews:@[ self.soundButton, self.pauseButton, self.layoutButton ]];
  self.toolbar.alignment = UIStackViewAlignmentCenter;
  self.toolbar.spacing = 8;
  self.toolbar.translatesAutoresizingMaskIntoConstraints = NO;
  [self.view addSubview:self.toolbar];
  UILayoutGuide *safe = self.view.safeAreaLayoutGuide;
  [NSLayoutConstraint activateConstraints:@[
    [self.game.leadingAnchor constraintEqualToAnchor:safe.leadingAnchor],
    [self.game.bottomAnchor constraintEqualToAnchor:self.view.keyboardLayoutGuide.topAnchor],
    [self.toolbar.trailingAnchor constraintEqualToAnchor:safe.trailingAnchor constant:-8]
  ]];
  self.portraitConstraints = @[
    [self.toolbar.topAnchor constraintEqualToAnchor:safe.topAnchor constant:4],
    [self.toolbar.heightAnchor constraintEqualToConstant:48],
    [self.game.topAnchor constraintEqualToAnchor:self.toolbar.bottomAnchor constant:4],
    [self.game.trailingAnchor constraintEqualToAnchor:safe.trailingAnchor]
  ];
  self.wideConstraints = @[
    [self.toolbar.centerYAnchor constraintEqualToAnchor:self.game.centerYAnchor],
    [self.toolbar.widthAnchor constraintEqualToConstant:48],
    [self.game.topAnchor constraintEqualToAnchor:safe.topAnchor],
    [self.game.trailingAnchor constraintEqualToAnchor:self.toolbar.leadingAnchor constant:-8]
  ];
  [self updateGameLayout];
  self.status = [UILabel new];
  self.status.translatesAutoresizingMaskIntoConstraints = NO;
  self.status.textColor = UIColor.whiteColor;
  self.status.textAlignment = NSTextAlignmentCenter;
  self.status.numberOfLines = 0;
  self.status.font = [UIFont preferredFontForTextStyle:UIFontTextStyleBody];
  self.status.adjustsFontForContentSizeCategory = YES;
  [self.view addSubview:self.status];
  self.restart = [UIButton buttonWithType:UIButtonTypeSystem];
  self.restart.translatesAutoresizingMaskIntoConstraints = NO;
  [self.restart setTitle:@"Play again" forState:UIControlStateNormal];
  self.restart.titleLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleHeadline];
  self.restart.titleLabel.adjustsFontForContentSizeCategory = YES;
  [self.restart addTarget:self
                   action:@selector(startGame)
         forControlEvents:UIControlEventTouchUpInside];
  [self.view addSubview:self.restart];
  [NSLayoutConstraint activateConstraints:@[
    [self.status.centerXAnchor constraintEqualToAnchor:self.view.centerXAnchor],
    [self.status.centerYAnchor constraintEqualToAnchor:self.view.centerYAnchor constant:-20],
    [self.status.widthAnchor constraintLessThanOrEqualToAnchor:safe.widthAnchor constant:-48],
    [self.restart.centerXAnchor constraintEqualToAnchor:self.view.centerXAnchor],
    [self.restart.topAnchor constraintEqualToAnchor:self.status.bottomAnchor constant:20],
    [self.restart.heightAnchor constraintGreaterThanOrEqualToConstant:44],
    [self.restart.widthAnchor constraintGreaterThanOrEqualToConstant:120]
  ]];
  [self startGame];
}
- (void)startGame {
  // One engine run owns its guest memory. Clean shutdown permits another run with saved data.
  if (self.running)
    return;
  self.running = YES;
  userPaused = NO;
  [self refreshHostActivity];
  self.restart.hidden = YES;
  self.game.hidden = NO;
  self.game.userInteractionEnabled = YES;
  self.game.frameImage = nil;
  self.status.hidden = NO;
  self.status.text = @"Loading Lemonade Tycoon…";
  UIApplication.sharedApplication.idleTimerDisabled = YES;
  NSString *resources = [NSBundle.mainBundle.resourcePath stringByAppendingPathComponent:@"Game"];
  NSString *saves =
      [NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES) firstObject];
  NSString *image =
      [NSBundle.mainBundle.resourcePath stringByAppendingPathComponent:@"cold-memory.bin"];
  dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
    lemon_keyboard_configure(presentKeyboard);
    lemon_url_configure(openGameURL);
    lemon_configure(resources.UTF8String, saves.UTF8String, presentFrame, presentDialog);
    int result = lemon_run(image.UTF8String);
    dispatch_async(dispatch_get_main_queue(), ^{
      self.running = NO;
      self.game.hidden = YES;
      self.game.userInteractionEnabled = NO;
      self.status.hidden = NO;
      self.status.text = result ? @"The game stopped unexpectedly." : @"Game closed.";
      self.restart.hidden = NO;
      UIApplication.sharedApplication.idleTimerDisabled = NO;
    });
  });
}
- (BOOL)prefersStatusBarHidden {
  return YES;
}
- (UIInterfaceOrientationMask)supportedInterfaceOrientations {
  return UIInterfaceOrientationMaskAllButUpsideDown;
}
@end
@interface LemonDelegate : UIResponder <UIApplicationDelegate>
@property(nonatomic, strong) UIWindow *window;
@end
@implementation LemonDelegate
- (BOOL)application:(UIApplication *)app didFinishLaunchingWithOptions:(NSDictionary *)options {
  [NSNotificationCenter.defaultCenter addObserver:self
                                         selector:@selector(audioInterrupted:)
                                             name:AVAudioSessionInterruptionNotification
                                           object:nil];
  [NSNotificationCenter.defaultCenter addObserver:self
                                         selector:@selector(audioConfigurationChanged:)
                                             name:AVAudioEngineConfigurationChangeNotification
                                           object:nil];
  frameLock = [NSLock new];
  userMuted = [NSUserDefaults.standardUserDefaults boolForKey:@"soundMuted"];
  self.window = [[UIWindow alloc] initWithFrame:UIScreen.mainScreen.bounds];
  self.window.rootViewController = [LemonController new];
  [self.window makeKeyAndVisible];
#ifdef LEMON_UI_SMOKE_TEST
  extern void lemon_ios_smoke_test(UIWindow * window);
  lemon_ios_smoke_test(self.window);
#endif
  return YES;
}
- (void)applicationWillResignActive:(UIApplication *)app {
  // Pause at the engine's cooperative boundary and exclude inactive time from its clock.
  appActive = NO;
  [controller.game cancelGameTouch];
  [controller refreshHostActivity];
  [AVAudioSession.sharedInstance setActive:NO
                               withOptions:AVAudioSessionSetActiveOptionNotifyOthersOnDeactivation
                                     error:NULL];
}
- (void)applicationDidBecomeActive:(UIApplication *)app {
  appActive = YES;
  [controller refreshHostActivity];
}
- (void)audioInterrupted:(NSNotification *)note {
  NSNumber *type = note.userInfo[AVAudioSessionInterruptionTypeKey];
  dispatch_async(dispatch_get_main_queue(), ^{
    audioInterrupted = type.unsignedIntegerValue == AVAudioSessionInterruptionTypeBegan;
    [controller refreshHostActivity];
  });
}
- (void)audioConfigurationChanged:(NSNotification *)note {
  dispatch_async(dispatch_get_main_queue(), ^{
    if (note.object == audioEngine)
      resumeAudio();
  });
}
@end
int main(int argc, char **argv) {
  @autoreleasepool {
    return UIApplicationMain(argc, argv, nil, NSStringFromClass(LemonDelegate.class));
  }
}
