#import "SettingsController.h"
#import "../../engine/save.h"
#import "../../engine/audio.h"
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>

static NSString *saveDirectory(void) {
  return NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES)
      .firstObject;
}
@interface LemonSettingsController () <UIDocumentPickerDelegate>
@property(nonatomic, strong) UIStackView *content;
@property(nonatomic, strong) UILabel *feedback;
@property(nonatomic, strong) UIButton *importButton, *closeButton;
@property(nonatomic, strong) NSMutableArray<UIButton *> *exports;
@property(nonatomic, strong) NSTimer *timer;
@end
@implementation LemonSettingsController
- (UILabel *)text:(NSString *)text {
  UILabel *label = [UILabel new];
  label.text = text;
  label.numberOfLines = 0;
  label.font = [UIFont preferredFontForTextStyle:UIFontTextStyleBody];
  label.adjustsFontForContentSizeCategory = YES;
  return label;
}
- (UIButton *)button:(NSString *)title action:(SEL)action {
  UIButton *button = [UIButton buttonWithType:UIButtonTypeSystem];
  button.configuration = [UIButtonConfiguration tintedButtonConfiguration];
  [button setTitle:title forState:UIControlStateNormal];
  [button.heightAnchor constraintGreaterThanOrEqualToConstant:48].active = YES;
  [button addTarget:self action:action forControlEvents:UIControlEventTouchUpInside];
  [self.content addArrangedSubview:button];
  return button;
}
- (void)viewDidLoad {
  [super viewDidLoad];
  self.title = @"Settings & saves";
  self.overrideUserInterfaceStyle = UIUserInterfaceStyleDark;
  self.view.backgroundColor = UIColor.systemBackgroundColor;
  self.navigationItem.rightBarButtonItem =
      [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemDone
                                                    target:self
                                                    action:@selector(done)];
  UIScrollView *scroll = [UIScrollView new];
  scroll.translatesAutoresizingMaskIntoConstraints = NO;
  [self.view addSubview:scroll];
  self.content = [UIStackView new];
  self.content.axis = UILayoutConstraintAxisVertical;
  self.content.spacing = 16;
  self.content.translatesAutoresizingMaskIntoConstraints = NO;
  [scroll addSubview:self.content];
  [NSLayoutConstraint activateConstraints:@[
    [scroll.topAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.topAnchor],
    [scroll.bottomAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.bottomAnchor],
    [scroll.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
    [scroll.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
    [self.content.topAnchor constraintEqualToAnchor:scroll.contentLayoutGuide.topAnchor
                                           constant:20],
    [self.content.bottomAnchor constraintEqualToAnchor:scroll.contentLayoutGuide.bottomAnchor
                                              constant:-20],
    [self.content.leadingAnchor constraintEqualToAnchor:scroll.contentLayoutGuide.leadingAnchor
                                               constant:20],
    [self.content.trailingAnchor constraintEqualToAnchor:scroll.contentLayoutGuide.trailingAnchor
                                                constant:-20],
    [self.content.widthAnchor constraintEqualToAnchor:scroll.frameLayoutGuide.widthAnchor
                                             constant:-40]
  ]];
  [self.content
      addArrangedSubview:
          [self text:@"Move all careers between iPhone, iPad, and the web. Exports include the "
                     @"latest normal checkpoint. An unfinished selling day is not included."]];
  self.feedback = [self text:@""];
  [self.content addArrangedSubview:self.feedback];
  self.exports = [NSMutableArray new];
  NSArray *titles =
      @[ @"Export latest save", @"Export previous backup", @"Export pre-import backup" ];
  for (unsigned i = 0; i < 3; i++) {
    UIButton *button = [self button:titles[i] action:@selector(exportSave:)];
    button.tag = i;
    [self.exports addObject:button];
  }
  self.importButton = [self button:@"Import save from Files" action:@selector(chooseImport)];
  self.closeButton = [self button:@"Close game to import" action:@selector(confirmClose)];
  [self.content
      addArrangedSubview:
          [self text:@"Each completed save keeps the previous checkpoint. Import replaces all "
                     @"careers and keeps a separate copy of your current save."]];
  NSArray *audioTitles = @[ @"Music & ambience", @"Sound effects" ];
  NSArray *audioKeys = @[ @"musicVolume", @"effectsVolume" ];
  for (unsigned i = 0; i < 2; i++) {
    [self.content addArrangedSubview:[self text:audioTitles[i]]];
    UISlider *slider = [UISlider new];
    slider.tag = i;
    slider.value = [NSUserDefaults.standardUserDefaults floatForKey:audioKeys[i]];
    slider.accessibilityLabel = audioTitles[i];
    slider.accessibilityValue = [NSString stringWithFormat:@"%.0f percent", slider.value * 100];
    [slider.heightAnchor constraintGreaterThanOrEqualToConstant:44].active = YES;
    [slider addTarget:self
                  action:@selector(volumeChanged:)
        forControlEvents:UIControlEventValueChanged];
    [self.content addArrangedSubview:slider];
  }
  UISwitch *haptics = [UISwitch new];
  haptics.on = [NSUserDefaults.standardUserDefaults boolForKey:@"hapticsEnabled"];
  haptics.accessibilityLabel = @"Action haptics";
  [haptics addTarget:self
                action:@selector(hapticsChanged:)
      forControlEvents:UIControlEventValueChanged];
  UIStackView *hapticRow =
      [[UIStackView alloc] initWithArrangedSubviews:@[ [self text:@"Action haptics"], haptics ]];
  hapticRow.alignment = UIStackViewAlignmentCenter;
  hapticRow.spacing = 16;
  [self.content addArrangedSubview:hapticRow];
  [self.content addArrangedSubview:[self text:@"Frame rate"]];
  UISegmentedControl *rate = [[UISegmentedControl alloc] initWithItems:@[ @"60 FPS", @"120 FPS" ]];
  rate.selectedSegmentIndex =
      [NSUserDefaults.standardUserDefaults integerForKey:@"frameRate"] == 60 ? 0 : 1;
  rate.accessibilityLabel = @"Frame rate limit";
  [rate.heightAnchor constraintGreaterThanOrEqualToConstant:44].active = YES;
  [rate addTarget:self
                action:@selector(frameRateChanged:)
      forControlEvents:UIControlEventValueChanged];
  [self.content addArrangedSubview:rate];
  [self.content
      addArrangedSubview:
          [self text:@"120 FPS uses more power and needs a supported display. Actual FPS depends "
                     @"on the scene and device. Low Power Mode limits the rate to 60 FPS."]];
  UISwitch *counter = [UISwitch new];
  counter.on = [NSUserDefaults.standardUserDefaults boolForKey:@"showFPS"];
  counter.accessibilityLabel = @"Show FPS counter";
  [counter addTarget:self
                action:@selector(fpsChanged:)
      forControlEvents:UIControlEventValueChanged];
  UIStackView *fpsRow =
      [[UIStackView alloc] initWithArrangedSubviews:@[ [self text:@"Show FPS counter"], counter ]];
  fpsRow.alignment = UIStackViewAlignmentCenter;
  fpsRow.spacing = 16;
  [self.content addArrangedSubview:fpsRow];
  [self refresh];
}
- (void)frameRateChanged:(UISegmentedControl *)control {
  [NSUserDefaults.standardUserDefaults setInteger:control.selectedSegmentIndex ? 120 : 60
                                           forKey:@"frameRate"];
  if (self.displaySettingsChanged)
    self.displaySettingsChanged();
}
- (void)fpsChanged:(UISwitch *)control {
  [NSUserDefaults.standardUserDefaults setBool:control.on forKey:@"showFPS"];
  if (self.displaySettingsChanged)
    self.displaySettingsChanged();
}
- (void)volumeChanged:(UISlider *)slider {
  [NSUserDefaults.standardUserDefaults setFloat:slider.value
                                         forKey:slider.tag ? @"effectsVolume" : @"musicVolume"];
  slider.accessibilityValue = [NSString stringWithFormat:@"%.0f percent", slider.value * 100];
  lemon_audio_levels([NSUserDefaults.standardUserDefaults floatForKey:@"musicVolume"],
                     [NSUserDefaults.standardUserDefaults floatForKey:@"effectsVolume"]);
}
- (void)hapticsChanged:(UISwitch *)control {
  [NSUserDefaults.standardUserDefaults setBool:control.on forKey:@"hapticsEnabled"];
}
- (void)viewDidAppear:(BOOL)animated {
  [super viewDidAppear:animated];
  __weak LemonSettingsController *weakSelf = self;
  self.timer = [NSTimer scheduledTimerWithTimeInterval:.5
                                               repeats:YES
                                                 block:^(NSTimer *timer) {
                                                   [weakSelf refresh];
                                                 }];
}
- (void)viewDidDisappear:(BOOL)animated {
  [super viewDidDisappear:animated];
  [self.timer invalidate];
}
- (void)refresh {
  LemonSaveStatus status;
  lemon_save_status(saveDirectory().UTF8String, &status);
  for (unsigned i = 0; i < 3; i++)
    self.exports[i].enabled = !!(status.available & (1 << i));
  BOOL running = self.isGameRunning && self.isGameRunning();
  self.importButton.enabled = !running;
  self.closeButton.hidden = !running;
}
- (void)done {
  [self dismissViewControllerAnimated:YES completion:nil];
}
- (void)exportSave:(UIButton *)sender {
  NSString *name =
      [NSString stringWithFormat:@"Lemonade-%@.lemonade-save",
                                 @[ @"latest", @"previous", @"before-import" ][sender.tag]];
  NSURL *url = [NSURL fileURLWithPath:[NSTemporaryDirectory() stringByAppendingPathComponent:name]];
  int result =
      lemon_save_export(saveDirectory().UTF8String, url.path.UTF8String, (unsigned)sender.tag);
  if (result) {
    self.feedback.text = @(lemon_save_message(result));
    return;
  }
  UIActivityViewController *share = [[UIActivityViewController alloc] initWithActivityItems:@[ url ]
                                                                      applicationActivities:nil];
  share.popoverPresentationController.sourceView = sender;
  share.popoverPresentationController.sourceRect = sender.bounds;
  [self presentViewController:share animated:YES completion:nil];
}
- (void)chooseImport {
  UIDocumentPickerViewController *picker =
      [[UIDocumentPickerViewController alloc] initForOpeningContentTypes:@[ UTTypeData ]
                                                                  asCopy:YES];
  picker.delegate = self;
  picker.allowsMultipleSelection = NO;
  [self presentViewController:picker animated:YES completion:nil];
}
- (void)documentPicker:(UIDocumentPickerViewController *)picker
    didPickDocumentsAtURLs:(NSArray<NSURL *> *)urls {
  NSURL *url = urls.firstObject;
  if (!url)
    return;
  int result = lemon_save_validate(url.path.UTF8String);
  if (result) {
    self.feedback.text = @(lemon_save_message(result));
    return;
  }
  UIAlertController *confirm = [UIAlertController
      alertControllerWithTitle:@"Replace all careers?"
                       message:@"Your current save will remain available as the pre-import backup."
                preferredStyle:UIAlertControllerStyleAlert];
  [confirm addAction:[UIAlertAction actionWithTitle:@"Cancel"
                                              style:UIAlertActionStyleCancel
                                            handler:nil]];
  [confirm addAction:
               [UIAlertAction
                   actionWithTitle:@"Import"
                             style:UIAlertActionStyleDestructive
                           handler:^(UIAlertAction *action) {
                             int imported =
                                 lemon_save_import(saveDirectory().UTF8String, url.path.UTF8String);
                             self.feedback.text =
                                 imported
                                     ? @(lemon_save_message(imported))
                                     : @"Imported. Tap Done, then Play again to load your careers.";
                             [self refresh];
                           }]];
  // File providers can deliver the selection before their picker finishes
  // closing. Present the confirmation after that transition, from this sheet.
  void (^showConfirmation)(void) = ^{
    [self presentViewController:confirm animated:YES completion:nil];
  };
  if (picker.presentingViewController)
    [picker dismissViewControllerAnimated:YES completion:showConfirmation];
  else
    showConfirmation();
}
- (void)confirmClose {
  UIAlertController *confirm =
      [UIAlertController alertControllerWithTitle:@"Close the game?"
                                          message:@"The latest normal checkpoint stays saved. "
                                                  @"Progress since that checkpoint will be lost."
                                   preferredStyle:UIAlertControllerStyleAlert];
  [confirm addAction:[UIAlertAction actionWithTitle:@"Cancel"
                                              style:UIAlertActionStyleCancel
                                            handler:nil]];
  [confirm addAction:[UIAlertAction actionWithTitle:@"Close game"
                                              style:UIAlertActionStyleDestructive
                                            handler:^(UIAlertAction *action) {
                                              if (self.closeGame)
                                                self.closeGame();
                                            }]];
  [self presentViewController:confirm animated:YES completion:nil];
}
@end
