#import <UIKit/UIKit.h>
#import <AVFoundation/AVFoundation.h>
#import <QuartzCore/QuartzCore.h>
#include <math.h>
#import "../../engine/audio.h"
#import "../../engine/platform.h"
#import "GameView.h"
#import "SettingsController.h"
#import "DashboardView.h"
#import "../../engine/save.h"
#ifdef LEMON_BENCHMARK
void lemon_benchmark_frame(BOOL delivered);
void lemon_benchmark_poll(void);
void lemon_benchmark_prepare(void);
void lemon_benchmark_start(UIWindow *window);
void lemon_benchmark_display_tick(void);
#endif

typedef NS_ENUM(NSInteger, LemonLayoutMode) {
  LemonLayoutFill,
  LemonLayoutFit,
  LemonLayoutOriginal,
  LemonLayoutAdaptive,
};

// UIKit and AVAudioEngine state is confined to the main thread.
static AVAudioEngine *audioEngine;
static BOOL audioRequested, audioInterrupted, appActive = YES, userPaused, userMuted;
static NSLock *frameLock;
static NSData *pendingFrame;

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
@property(nonatomic, strong) UIVisualEffectView *toolbarBackdrop;
@property(nonatomic, strong) UIButton *hideControlsButton, *showControlsButton;
@property(nonatomic, strong) LemonDashboardView *dashboard;
@property(nonatomic, strong) NSTimer *hostTimer;
@property(nonatomic, strong) CADisplayLink *displayLink;
@property(nonatomic, strong) UILabel *fpsLabel;
@property(nonatomic) unsigned frameRateLimit, fpsFrames;
@property(nonatomic) CFTimeInterval fpsStarted;
@property(nonatomic, strong) UILabel *saveNotice;
@property(nonatomic) unsigned lastSaveRevision;
@property(nonatomic, strong) NSArray<NSLayoutConstraint *> *portraitConstraints, *wideConstraints;
- (void)refreshHostActivity;
- (void)refreshDisplaySettings;
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
#ifdef LEMON_BENCHMARK
  lemon_benchmark_frame(NO);
#endif
  @autoreleasepool {
    // The display link consumes only the latest frame. Slow layout or a lower
    // system refresh rate cannot create an unbounded queue of UIKit updates.
    NSData *data = [NSData dataWithBytes:rgb length:width * height * 4];
    [frameLock lock];
    pendingFrame = data;
    [frameLock unlock];
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
  self.displayLink.paused = !hostActive() || !self.running;
  self.fpsStarted = CACurrentMediaTime();
  self.fpsFrames = 0;
  self.fpsLabel.text = @"0\nFPS";
  self.fpsLabel.accessibilityValue = @"0 frames per second";
  self.hostTimer.fireDate = hostActive() && self.running ? NSDate.date : NSDate.distantFuture;
  UIApplication.sharedApplication.idleTimerDisabled = hostActive() && self.running;
  if (hostActive())
    resumeAudio();
  else
    [audioEngine pause];
  self.game.userInteractionEnabled = self.running && !userPaused;
  self.dashboard.userInteractionEnabled = self.running && !userPaused;
  self.pauseButton.accessibilityLabel = userPaused ? @"Resume game" : @"Pause game";
  self.pauseButton.toolTip = self.pauseButton.accessibilityLabel;
  UIButtonConfiguration *style = self.pauseButton.configuration;
  style.image = [UIImage systemImageNamed:userPaused ? @"play.fill" : @"pause.fill"];
  self.pauseButton.configuration = style;
}
- (void)refreshDisplaySettings {
  UIScreen *screen = self.view.window.screen ?: UIScreen.mainScreen;
  unsigned selected =
      [NSUserDefaults.standardUserDefaults integerForKey:@"frameRate"] == 60 ? 60 : 120;
  self.frameRateLimit = MIN(selected, screen.maximumFramesPerSecond);
  if (NSProcessInfo.processInfo.lowPowerModeEnabled)
    self.frameRateLimit = MIN(self.frameRateLimit, 60);
  float maximum = MAX(1, self.frameRateLimit);
  self.displayLink.preferredFrameRateRange =
      CAFrameRateRangeMake(MIN(maximum, maximum > 60 ? 80 : 30), maximum, maximum);
  lemon_set_frame_rate(self.frameRateLimit);
  self.fpsLabel.hidden = ![NSUserDefaults.standardUserDefaults boolForKey:@"showFPS"];
}
- (void)displayTick:(CADisplayLink *)link {
  if (!self.running || !hostActive())
    return;
#ifdef LEMON_BENCHMARK
  lemon_benchmark_display_tick();
#endif
  // Follow the rate the system actually grants, including Low Power Mode and
  // display changes. A 120 Hz preference never forces 120 software redraws on 60 Hz.
  CFTimeInterval interval = link.targetTimestamp - link.timestamp;
  if (interval > 0)
    lemon_set_frame_rate(MIN(self.frameRateLimit, MAX(1, (unsigned)lround(1 / interval))));
  [frameLock lock];
  NSData *latest = pendingFrame;
  pendingFrame = nil;
  [frameLock unlock];
  if (!latest)
    return;
  CGDataProviderRef provider = CGDataProviderCreateWithCFData((__bridge CFDataRef)latest);
  CGColorSpaceRef colors = CGColorSpaceCreateDeviceRGB();
  CGImageRef cg = CGImageCreate(640, 480, 8, 32, 640 * 4, colors,
                                kCGBitmapByteOrder32Little | kCGImageAlphaNoneSkipFirst, provider,
                                NULL, NO, kCGRenderingIntentDefault);
  UIImage *image = [UIImage imageWithCGImage:cg];
  self.game.frameImage = image;
  self.dashboard.frameImage = image;
  self.fpsFrames++;
#ifdef LEMON_BENCHMARK
  lemon_benchmark_frame(YES);
#endif
  CGImageRelease(cg);
  CGColorSpaceRelease(colors);
  CGDataProviderRelease(provider);
  self.status.hidden = YES;
}
- (void)updateFPS {
  CFTimeInterval now = CACurrentMediaTime(), elapsed = now - self.fpsStarted;
  if (elapsed < 1)
    return;
  unsigned fps = (unsigned)lround(self.fpsFrames / elapsed);
  self.fpsLabel.text = [NSString stringWithFormat:@"%u\nFPS", fps];
  self.fpsLabel.accessibilityValue = [NSString stringWithFormat:@"%u frames per second", fps];
  self.fpsFrames = 0;
  self.fpsStarted = now;
}
- (void)togglePause {
  [self.dashboard cancelGameTouch];
  [self.game cancelGameTouch];
  [self.game resignFirstResponder];
  userPaused = !userPaused;
  if ([NSUserDefaults.standardUserDefaults boolForKey:@"hapticsEnabled"])
    [[UISelectionFeedbackGenerator new] selectionChanged];
  [self refreshHostActivity];
  UIAccessibilityPostNotification(UIAccessibilityAnnouncementNotification,
                                  userPaused ? @"Game paused" : @"Game resumed");
}
- (void)setControlsHidden:(BOOL)hidden {
  [self.dashboard cancelGameTouch];
  [self.game cancelGameTouch];
  [self.game resignFirstResponder];
  [NSUserDefaults.standardUserDefaults setBool:hidden forKey:@"controlsHidden"];
  self.toolbar.hidden = hidden;
  self.toolbarBackdrop.hidden = hidden;
  self.showControlsButton.hidden = !hidden;
  UIAccessibilityPostNotification(UIAccessibilityLayoutChangedNotification,
                                  hidden ? self.showControlsButton : self.hideControlsButton);
}
- (void)hideControls {
  [self setControlsHidden:YES];
}
- (void)showControls {
  [self setControlsHidden:NO];
}
- (void)showSettings {
  [self.dashboard cancelGameTouch];
  [self.game cancelGameTouch];
  [self.game resignFirstResponder];
  LemonSettingsController *settings = [LemonSettingsController new];
  __weak LemonController *weakSelf = self;
  settings.isGameRunning = ^BOOL {
    return weakSelf.running;
  };
  settings.displaySettingsChanged = ^{
    [weakSelf refreshDisplaySettings];
  };
  settings.closeGame = ^{
    userPaused = NO;
    [weakSelf refreshHostActivity];
    lemon_request_quit();
  };
  UINavigationController *sheet =
      [[UINavigationController alloc] initWithRootViewController:settings];
  sheet.overrideUserInterfaceStyle = UIUserInterfaceStyleDark;
  sheet.sheetPresentationController.detents = @[ UISheetPresentationControllerDetent.largeDetent ];
  [self presentViewController:sheet animated:YES completion:nil];
}
- (void)toggleSound {
  [self.dashboard cancelGameTouch];
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
  if (![NSUserDefaults.standardUserDefaults objectForKey:@"gameLayout"])
    return LemonLayoutAdaptive;
  NSInteger mode = [NSUserDefaults.standardUserDefaults integerForKey:@"gameLayout"];
  return mode >= LemonLayoutFill && mode <= LemonLayoutAdaptive ? mode : LemonLayoutAdaptive;
}
- (void)selectGameLayout:(LemonLayoutMode)mode {
  [self.dashboard cancelGameTouch];
  [self.game cancelGameTouch];
  [self.game resignFirstResponder];
  [NSUserDefaults.standardUserDefaults setInteger:mode forKey:@"gameLayout"];
  [self updateLayoutMenu];
  [self.view setNeedsLayout];
  UIAccessibilityPostNotification(UIAccessibilityAnnouncementNotification,
                                  self.layoutButton.accessibilityValue);
}
- (void)updateLayoutMenu {
  NSArray<NSString *> *titles =
      @[ @"Fill screen", @"Keep proportions", @"Original layout", @"Adaptive interface" ];
  NSMutableArray<UIAction *> *actions = [NSMutableArray new];
  LemonLayoutMode selected = [self gameLayoutMode];
  __weak LemonController *weakSelf = self;
  for (LemonLayoutMode mode = LemonLayoutFill; mode <= LemonLayoutAdaptive; mode++) {
    UIAction *action = [UIAction actionWithTitle:titles[mode]
                                           image:nil
                                      identifier:nil
                                         handler:^(UIAction *sender) {
                                           [weakSelf selectGameLayout:mode];
                                         }];
    action.state = mode == selected ? UIMenuElementStateOn : UIMenuElementStateOff;
    [actions addObject:action];
  }
  [actions addObject:[UIAction actionWithTitle:@"Settings & saves"
                                         image:[UIImage systemImageNamed:@"gearshape"]
                                    identifier:nil
                                       handler:^(UIAction *sender) {
                                         [weakSelf showSettings];
                                       }]];
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
    // The toolbar floats above the game; rotating or hiding it never resizes
    // the play area. Only its own row/rail constraints change.
    self.toolbar.axis = wide ? UILayoutConstraintAxisVertical : UILayoutConstraintAxisHorizontal;
    self.toolbar.spacing = wide ? 4 : 8;
    [NSLayoutConstraint activateConstraints:active];
  }
  LemonLayoutMode mode = [self gameLayoutMode];
  LemonGameState state;
  lemon_game_state(&state);
  BOOL adaptive = self.running && mode == LemonLayoutAdaptive && state.loaded &&
                  !state.modal_open && !self.game.textActive;
  self.dashboard.hidden = !adaptive;
  self.game.hidden = !self.running || adaptive;
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
  self.dashboard = [LemonDashboardView new];
  self.dashboard.translatesAutoresizingMaskIntoConstraints = NO;
  __weak LemonController *weakSelf = self;
  [self.view addSubview:self.dashboard];
  [NSLayoutConstraint activateConstraints:@[
    [self.dashboard.topAnchor constraintEqualToAnchor:self.game.topAnchor],
    [self.dashboard.bottomAnchor constraintEqualToAnchor:self.game.bottomAnchor],
    [self.dashboard.leadingAnchor constraintEqualToAnchor:self.game.leadingAnchor],
    [self.dashboard.trailingAnchor constraintEqualToAnchor:self.game.trailingAnchor]
  ]];
  self.soundButton = [self button:userMuted ? @"speaker.slash.fill" : @"speaker.wave.2.fill"
                            label:userMuted ? @"Unmute sound" : @"Mute sound"
                           action:@selector(toggleSound)];
  self.pauseButton = [self button:@"pause.fill" label:@"Pause game" action:@selector(togglePause)];
  self.layoutButton = [self button:@"rectangle.split.1x2" label:@"Game layout" action:NULL];
  self.layoutButton.showsMenuAsPrimaryAction = YES;
  self.hideControlsButton = [self button:@"eye.slash"
                                   label:@"Hide controls"
                                  action:@selector(hideControls)];
  self.showControlsButton = [self button:@"ellipsis"
                                   label:@"Show controls"
                                  action:@selector(showControls)];
  self.showControlsButton.translatesAutoresizingMaskIntoConstraints = NO;
  self.showControlsButton.backgroundColor =
      [UIColor.secondarySystemBackgroundColor colorWithAlphaComponent:.85];
  self.showControlsButton.layer.cornerRadius = 24;
  self.showControlsButton.clipsToBounds = YES;
  [self updateLayoutMenu];
  self.fpsLabel = [UILabel new];
  self.fpsLabel.numberOfLines = 2;
  self.fpsLabel.textAlignment = NSTextAlignmentCenter;
  self.fpsLabel.font = [UIFont monospacedDigitSystemFontOfSize:12 weight:UIFontWeightMedium];
  self.fpsLabel.textColor = UIColor.systemYellowColor;
  self.fpsLabel.accessibilityLabel = @"Game frame rate";
  NSLayoutConstraint *fpsWidth = [self.fpsLabel.widthAnchor constraintEqualToConstant:48];
  fpsWidth.priority = UILayoutPriorityDefaultHigh; // Hidden stack items collapse to zero.
  fpsWidth.active = YES;
  self.toolbar = [[UIStackView alloc] initWithArrangedSubviews:@[
    self.soundButton, self.pauseButton, self.layoutButton, self.fpsLabel, self.hideControlsButton
  ]];
  self.toolbar.alignment = UIStackViewAlignmentCenter;
  self.toolbar.spacing = 8;
  self.toolbar.translatesAutoresizingMaskIntoConstraints = NO;
  self.toolbarBackdrop = [[UIVisualEffectView alloc]
      initWithEffect:[UIBlurEffect effectWithStyle:UIBlurEffectStyleSystemChromeMaterialDark]];
  self.toolbarBackdrop.translatesAutoresizingMaskIntoConstraints = NO;
  self.toolbarBackdrop.layer.cornerRadius = 20;
  self.toolbarBackdrop.clipsToBounds = YES;
  [self.toolbarBackdrop.contentView addSubview:self.toolbar];
  [self.view addSubview:self.toolbarBackdrop];
  [self.view addSubview:self.showControlsButton];
  UILayoutGuide *safe = self.view.safeAreaLayoutGuide;
  // iPhone needs breathing room around its camera and home indicator. The
  // border belongs to the game frame, so toolbar visibility never changes it.
  BOOL phone = self.traitCollection.userInterfaceIdiom == UIUserInterfaceIdiomPhone;
  CGFloat border = phone ? 8 : 0;
  self.view.keyboardLayoutGuide.usesBottomSafeArea = phone;
  for (UIView *surface in @[ self.game, self.dashboard ]) {
    surface.layer.cornerRadius = phone ? 10 : 0;
    surface.layer.borderWidth = phone ? 1 : 0;
    surface.layer.borderColor = [UIColor colorWithWhite:.2 alpha:1].CGColor;
    surface.clipsToBounds = YES;
  }
  [NSLayoutConstraint activateConstraints:@[
    [self.game.leadingAnchor
        constraintEqualToAnchor:phone ? safe.leadingAnchor : self.view.leadingAnchor
                       constant:border],
    [self.game.trailingAnchor
        constraintEqualToAnchor:phone ? safe.trailingAnchor : self.view.trailingAnchor
                       constant:-border],
    [self.game.topAnchor constraintEqualToAnchor:phone ? safe.topAnchor : self.view.topAnchor
                                        constant:border],
    [self.game.bottomAnchor constraintEqualToAnchor:self.view.keyboardLayoutGuide.topAnchor
                                           constant:-border],
    [self.toolbar.leadingAnchor
        constraintEqualToAnchor:self.toolbarBackdrop.contentView.leadingAnchor
                       constant:6],
    [self.toolbar.trailingAnchor
        constraintEqualToAnchor:self.toolbarBackdrop.contentView.trailingAnchor
                       constant:-6],
    [self.toolbar.topAnchor constraintEqualToAnchor:self.toolbarBackdrop.contentView.topAnchor
                                           constant:6],
    [self.toolbar.bottomAnchor constraintEqualToAnchor:self.toolbarBackdrop.contentView.bottomAnchor
                                              constant:-6],
    [self.toolbarBackdrop.trailingAnchor constraintEqualToAnchor:safe.trailingAnchor constant:-8],
    [self.showControlsButton.trailingAnchor constraintEqualToAnchor:safe.trailingAnchor
                                                           constant:-8],
    [self.showControlsButton.topAnchor constraintEqualToAnchor:safe.topAnchor constant:8],
    [self.showControlsButton.heightAnchor constraintEqualToConstant:48]
  ]];
  self.portraitConstraints = @[
    [self.toolbarBackdrop.topAnchor constraintEqualToAnchor:safe.topAnchor constant:8],
    [self.toolbar.heightAnchor constraintEqualToConstant:48]
  ];
  self.wideConstraints = @[
    [self.toolbarBackdrop.centerYAnchor constraintEqualToAnchor:safe.centerYAnchor],
    [self.toolbar.widthAnchor constraintEqualToConstant:48]
  ];
  BOOL controlsHidden = [NSUserDefaults.standardUserDefaults boolForKey:@"controlsHidden"];
  self.toolbar.hidden = self.toolbarBackdrop.hidden = controlsHidden;
  self.showControlsButton.hidden = !controlsHidden;
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
  self.displayLink = [CADisplayLink displayLinkWithTarget:self selector:@selector(displayTick:)];
  self.displayLink.paused = YES;
  [self.displayLink addToRunLoop:NSRunLoop.mainRunLoop forMode:NSRunLoopCommonModes];
  [self refreshDisplaySettings];
  [self startGame];
  self.saveNotice = [UILabel new];
  self.saveNotice.translatesAutoresizingMaskIntoConstraints = NO;
  self.saveNotice.font = [UIFont preferredFontForTextStyle:UIFontTextStyleCaption1];
  self.saveNotice.adjustsFontForContentSizeCategory = YES;
  self.saveNotice.numberOfLines = 0;
  self.saveNotice.backgroundColor =
      [UIColor.secondarySystemBackgroundColor colorWithAlphaComponent:.95];
  self.saveNotice.textAlignment = NSTextAlignmentCenter;
  self.saveNotice.alpha = 0;
  self.saveNotice.layer.cornerRadius = 8;
  self.saveNotice.clipsToBounds = YES;
  self.saveNotice.userInteractionEnabled = NO;
  [self.view addSubview:self.saveNotice];
  [NSLayoutConstraint activateConstraints:@[
    [self.saveNotice.leadingAnchor constraintEqualToAnchor:self.game.leadingAnchor constant:12],
    [self.saveNotice.bottomAnchor constraintEqualToAnchor:self.game.bottomAnchor constant:-8],
    [self.saveNotice.widthAnchor constraintLessThanOrEqualToAnchor:self.game.widthAnchor
                                                          constant:-24],
    [self.saveNotice.heightAnchor constraintGreaterThanOrEqualToConstant:32]
  ]];
  self.hostTimer = [NSTimer scheduledTimerWithTimeInterval:.25
                                                   repeats:YES
                                                     block:^(NSTimer *timer) {
#ifdef LEMON_BENCHMARK
                                                       lemon_benchmark_poll();
#endif
                                                       LemonGameState state;
                                                       lemon_game_state(&state);
                                                       [weakSelf.dashboard refresh:state];
                                                       [weakSelf updateGameLayout];
                                                       [weakSelf updateSaveFeedback];
                                                       [weakSelf updateFPS];
                                                     }];
  self.hostTimer.tolerance = .05;
}
- (void)updateSaveFeedback {
  NSString *directory =
      NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES).firstObject;
  LemonSaveStatus saved;
  lemon_save_status(directory.UTF8String, &saved);
  if (saved.revision == self.lastSaveRevision)
    return;
  self.lastSaveRevision = saved.revision;
  self.saveNotice.text =
      saved.result ? @"  Checkpoint failed. Previous save retained.  " : @"  Checkpoint saved  ";
  self.saveNotice.alpha = 1;
  unsigned revision = saved.revision;
  dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 3 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
    if (self.lastSaveRevision == revision)
      [UIView animateWithDuration:.3
                       animations:^{
                         self.saveNotice.alpha = 0;
                       }];
  });
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
      self.displayLink.paused = YES;
      self.fpsLabel.text = @"0\nFPS";
      self.hostTimer.fireDate = NSDate.distantFuture;
      self.game.hidden = YES;
      self.game.userInteractionEnabled = NO;
      self.status.hidden = NO;
      self.status.text = result ? @"The game stopped unexpectedly." : @"Game closed.";
      self.restart.hidden = NO;
      UIApplication.sharedApplication.idleTimerDisabled = NO;
    });
  });
}
- (BOOL)prefersHomeIndicatorAutoHidden {
  return YES;
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
  [NSNotificationCenter.defaultCenter addObserver:self
                                         selector:@selector(powerStateChanged:)
                                             name:NSProcessInfoPowerStateDidChangeNotification
                                           object:nil];
  frameLock = [NSLock new];
  [NSUserDefaults.standardUserDefaults registerDefaults:@{
    @"musicVolume" : @1,
    @"effectsVolume" : @1,
    @"hapticsEnabled" : @NO,
    @"frameRate" : @120,
    @"showFPS" : @YES
  }];
  lemon_audio_levels([NSUserDefaults.standardUserDefaults floatForKey:@"musicVolume"],
                     [NSUserDefaults.standardUserDefaults floatForKey:@"effectsVolume"]);
  userMuted = [NSUserDefaults.standardUserDefaults boolForKey:@"soundMuted"];
#ifdef LEMON_BENCHMARK
  lemon_benchmark_prepare();
#endif
  self.window = [[UIWindow alloc] initWithFrame:UIScreen.mainScreen.bounds];
  self.window.rootViewController = [LemonController new];
  [self.window makeKeyAndVisible];
#ifdef LEMON_BENCHMARK
  lemon_benchmark_start(self.window);
#endif
#ifdef LEMON_UI_SMOKE_TEST
  extern void lemon_ios_smoke_test(UIWindow * window);
  lemon_ios_smoke_test(self.window);
#endif
  return YES;
}
- (void)applicationWillResignActive:(UIApplication *)app {
  // Pause at the engine's cooperative boundary and exclude inactive time from its clock.
  appActive = NO;
  [controller.dashboard cancelGameTouch];
  [controller.game cancelGameTouch];
  [controller refreshHostActivity];
  [AVAudioSession.sharedInstance setActive:NO
                               withOptions:AVAudioSessionSetActiveOptionNotifyOthersOnDeactivation
                                     error:NULL];
}
- (void)applicationDidBecomeActive:(UIApplication *)app {
  appActive = YES;
  [controller refreshDisplaySettings];
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
- (void)powerStateChanged:(NSNotification *)note {
  dispatch_async(dispatch_get_main_queue(), ^{
    [controller refreshDisplaySettings];
  });
}
@end
int main(int argc, char **argv) {
  @autoreleasepool {
    return UIApplicationMain(argc, argv, nil, NSStringFromClass(LemonDelegate.class));
  }
}
