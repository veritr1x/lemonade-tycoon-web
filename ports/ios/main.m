#import <UIKit/UIKit.h>
#import <AVFoundation/AVFoundation.h>
#import "../../engine/audio.h"
#import "../../engine/platform.h"

// UIKit and AVAudioEngine state is confined to the main thread.
static AVAudioEngine *audioEngine;
static BOOL audioRequested, audioInterrupted, appActive = YES;
static BOOL resumeAudio(void) {
  if (!audioRequested || !appActive || audioInterrupted)
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

@interface LemonView : UIView <UIKeyInput>
@property(nonatomic, strong) UIImageView *image;
@property(nonatomic) CGRect textRect;
@property(nonatomic) BOOL textActive;
@property(nonatomic) CGFloat keyboardHeight;
@property(nonatomic) CGRect gestureRect;
@property(nonatomic) BOOL dismissingGesture;
- (void)updateTextActive:(BOOL)active rect:(CGRect)rect;
@end
@implementation LemonView
- (instancetype)initWithFrame:(CGRect)frame {
  if ((self = [super initWithFrame:frame])) {
    self.backgroundColor = UIColor.blackColor;
    _image = [[UIImageView alloc] initWithFrame:self.bounds];
    _image.contentMode = UIViewContentModeScaleAspectFit;
    _image.layer.magnificationFilter = kCAFilterNearest;
    [self addSubview:_image];
    self.multipleTouchEnabled = NO;
    [NSNotificationCenter.defaultCenter addObserver:self
                                           selector:@selector(keyboardChanged:)
                                               name:UIKeyboardWillChangeFrameNotification
                                             object:nil];
  }
  return self;
}
- (void)dealloc {
  [NSNotificationCenter.defaultCenter removeObserver:self];
}
- (CGRect)gameRect {
  // Keep the original 640x480 surface visible above the software keyboard.
  CGFloat width = self.bounds.size.width,
          height = MAX(1, self.bounds.size.height - self.keyboardHeight);
  CGFloat scale = MIN(width / 640, height / 480);
  return CGRectMake((width - 640 * scale) / 2, (height - 480 * scale) / 2, 640 * scale,
                    480 * scale);
}
- (void)layoutSubviews {
  [super layoutSubviews];
  self.image.frame = [self gameRect];
}
- (void)keyboardChanged:(NSNotification *)note {
  CGRect screen = [note.userInfo[UIKeyboardFrameEndUserInfoKey] CGRectValue];
  CGRect keyboard = [self convertRect:screen fromView:nil];
  self.keyboardHeight = CGRectIntersectsRect(self.bounds, keyboard)
                            ? self.bounds.size.height - MAX(0, keyboard.origin.y)
                            : 0;
  [self setNeedsLayout];
}
- (void)updateTextActive:(BOOL)active rect:(CGRect)rect {
  self.textActive = active;
  self.textRect = rect;
  if (active)
    [self becomeFirstResponder];
  else
    [self resignFirstResponder];
}
- (BOOL)canBecomeFirstResponder {
  return self.textActive;
}
- (BOOL)hasText {
  return YES;
}
- (void)insertText:(NSString *)text {
  for (NSUInteger i = 0; i < text.length; i++) {
    unichar c = [text characterAtIndex:i];
    if (c <= 255)
      lemon_key(c == '\n' ? 13 : c);
  }
}
- (void)deleteBackward {
  lemon_key(8);
}
- (UIKeyboardType)keyboardType {
  return UIKeyboardTypeASCIICapable;
}
- (UITextAutocorrectionType)autocorrectionType {
  return UITextAutocorrectionTypeNo;
}
- (CGPoint)gamePoint:(CGPoint)p rect:(CGRect)rect {
  return CGPointMake((p.x - rect.origin.x) * 640 / rect.size.width,
                     (p.y - rect.origin.y) * 480 / rect.size.height);
}
- (void)sendTouch:(NSSet<UITouch *> *)touches phase:(int)phase {
  // Freeze the transform for this gesture. An outside tap only dismisses typing.
  CGPoint local = [touches.anyObject locationInView:self];
  if (phase == 0) {
    self.gestureRect = [self gameRect];
    self.dismissingGesture = NO;
    CGPoint point = [self gamePoint:local rect:self.gestureRect];
    if (self.isFirstResponder && !CGRectContainsPoint(CGRectInset(self.textRect, -8, -8), point)) {
      self.dismissingGesture = YES;
      [self resignFirstResponder];
      return;
    }
    if (self.textActive && CGRectContainsPoint(CGRectInset(self.textRect, -8, -8), point))
      [self becomeFirstResponder];
  }
  if (self.dismissingGesture)
    return;
  CGPoint point = [self gamePoint:local rect:self.gestureRect];
  if (point.x >= 0 && point.x < 640 && point.y >= 0 && point.y < 480)
    lemon_touch(point.x, point.y, phase);
}
- (void)touchesBegan:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
  [self sendTouch:touches phase:0];
}
- (void)touchesMoved:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
  [self sendTouch:touches phase:1];
}
- (void)touchesEnded:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
  [self sendTouch:touches phase:2];
}
- (void)touchesCancelled:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
  [self sendTouch:touches phase:2];
}
@end
@interface LemonController : UIViewController
@property(nonatomic, strong) LemonView *game;
@property(nonatomic, strong) UILabel *status;
@property(nonatomic, strong) UIButton *restart;
@property(nonatomic) BOOL running;
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
  // Copy pixels before returning to the engine, which reuses its framebuffer.
  @autoreleasepool {
    NSData *data = [NSData dataWithBytes:rgb length:width * height * 4];
    CGDataProviderRef provider = CGDataProviderCreateWithCFData((__bridge CFDataRef)data);
    CGColorSpaceRef colors = CGColorSpaceCreateDeviceRGB();
    CGImageRef cg = CGImageCreate(width, height, 8, 32, width * 4, colors,
                                  kCGBitmapByteOrder32Little | kCGImageAlphaNoneSkipFirst, provider,
                                  NULL, NO, kCGRenderingIntentDefault);
    UIImage *im = [UIImage imageWithCGImage:cg];
    CGImageRelease(cg);
    CGColorSpaceRelease(colors);
    CGDataProviderRelease(provider);
    dispatch_async(dispatch_get_main_queue(), ^{
      controller.game.image.image = im;
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
- (void)viewDidLoad {
  [super viewDidLoad];
  controller = self;
  self.view.backgroundColor = UIColor.blackColor;
  self.game = [[LemonView alloc] initWithFrame:self.view.bounds];
  self.game.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
  [self.view addSubview:self.game];
  self.status = [UILabel new];
  self.status.translatesAutoresizingMaskIntoConstraints = NO;
  self.status.textColor = UIColor.whiteColor;
  self.status.textAlignment = NSTextAlignmentCenter;
  [self.view addSubview:self.status];
  self.restart = [UIButton buttonWithType:UIButtonTypeSystem];
  self.restart.translatesAutoresizingMaskIntoConstraints = NO;
  [self.restart setTitle:@"Play again" forState:UIControlStateNormal];
  [self.restart addTarget:self
                   action:@selector(startGame)
         forControlEvents:UIControlEventTouchUpInside];
  [self.view addSubview:self.restart];
  [NSLayoutConstraint activateConstraints:@[
    [self.status.centerXAnchor constraintEqualToAnchor:self.view.centerXAnchor],
    [self.status.centerYAnchor constraintEqualToAnchor:self.view.centerYAnchor constant:-20],
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
  self.restart.hidden = YES;
  self.game.hidden = NO;
  self.game.userInteractionEnabled = YES;
  self.game.image.image = nil;
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
  return UIInterfaceOrientationMaskLandscape;
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
  self.window = [[UIWindow alloc] initWithFrame:UIScreen.mainScreen.bounds];
  self.window.rootViewController = [LemonController new];
  [self.window makeKeyAndVisible];
  return YES;
}
- (void)applicationWillResignActive:(UIApplication *)app {
  // Pause at the engine's cooperative boundary and exclude inactive time from its clock.
  appActive = NO;
  lemon_set_active(0);
  [audioEngine pause];
  [AVAudioSession.sharedInstance setActive:NO
                               withOptions:AVAudioSessionSetActiveOptionNotifyOthersOnDeactivation
                                     error:NULL];
}
- (void)applicationDidBecomeActive:(UIApplication *)app {
  appActive = YES;
  lemon_set_active(1);
  resumeAudio();
}
- (void)audioInterrupted:(NSNotification *)note {
  NSNumber *type = note.userInfo[AVAudioSessionInterruptionTypeKey];
  dispatch_async(dispatch_get_main_queue(), ^{
    audioInterrupted = type.unsignedIntegerValue == AVAudioSessionInterruptionTypeBegan;
    if (audioInterrupted)
      [audioEngine pause];
    else
      resumeAudio();
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
