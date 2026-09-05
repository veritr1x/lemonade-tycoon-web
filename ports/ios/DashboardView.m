#import "DashboardView.h"
#import "GameView.h"
#import "layout.h"

// The visible separator stays small; its 44-point hit area is easy to grab.
// VoiceOver adjusts the same split as the pan gesture, without game input.
@interface LemonPaneDivider : UIView
@property(nonatomic) BOOL vertical;
@property(nonatomic, copy) void (^adjust)(CGFloat delta);
@property(nonatomic, copy) void (^reset)(void);
@property(nonatomic, strong) UIView *line, *grip;
@end
@implementation LemonPaneDivider
- (instancetype)initWithFrame:(CGRect)frame {
  if (!(self = [super initWithFrame:frame]))
    return nil;
  self.isAccessibilityElement = YES;
  self.accessibilityLabel = @"Resize game panes";
  self.accessibilityHint = @"Adjust the controls size. Double-tap to restore the default split.";
  self.accessibilityTraits = UIAccessibilityTraitAdjustable;
  _line = [UIView new];
  _line.backgroundColor = [UIColor colorWithWhite:1 alpha:.18];
  _grip = [UIView new];
  _grip.backgroundColor = [UIColor colorWithRed:.96 green:.85 blue:.29 alpha:1];
  _grip.layer.cornerRadius = 2;
  for (UIView *view in @[ _line, _grip ]) {
    view.userInteractionEnabled = NO;
    [self addSubview:view];
  }
  return self;
}
- (BOOL)pointInside:(CGPoint)point withEvent:(UIEvent *)event {
  return CGRectContainsPoint(
      CGRectInset(self.bounds, self.vertical ? -14 : 0, self.vertical ? 0 : -14), point);
}
- (void)layoutSubviews {
  [super layoutSubviews];
  CGFloat w = self.bounds.size.width, h = self.bounds.size.height;
  self.line.frame = self.vertical ? CGRectMake(w / 2, 0, 1, h) : CGRectMake(0, h / 2, w, 1);
  self.grip.frame = self.vertical ? CGRectMake(w / 2 - 2, h / 2 - 24, 4, 48)
                                  : CGRectMake(w / 2 - 24, h / 2 - 2, 48, 4);
}
- (void)accessibilityIncrement {
  if (self.adjust)
    self.adjust(.025);
}
- (void)accessibilityDecrement {
  if (self.adjust)
    self.adjust(-.025);
}
- (BOOL)accessibilityActivate {
  if (self.reset)
    self.reset();
  return YES;
}
@end

@interface LemonDashboardView ()
@property(nonatomic, strong) UILabel *hud;
@property(nonatomic, strong) UIImageView *weather;
@property(nonatomic, strong) LemonView *street, *controls;
@property(nonatomic, strong) LemonPaneDivider *divider;
@property(nonatomic) CGFloat portraitSplit, wideSplit, dragLength, dragSpan;
@property(nonatomic) BOOL resizing, dragWide;
@end
@implementation LemonDashboardView
- (instancetype)initWithFrame:(CGRect)frame {
  if (!(self = [super initWithFrame:frame]))
    return nil;
  self.backgroundColor = [UIColor colorWithRed:.027 green:.078 blue:.047 alpha:1];
  self.overrideUserInterfaceStyle = UIUserInterfaceStyleDark;
  NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
  id portrait = [defaults objectForKey:@"adaptivePortraitSplit"];
  id wide = [defaults objectForKey:@"adaptiveWideSplit"];
  _portraitSplit = lemon_adaptive_split(
      [portrait isKindOfClass:NSNumber.class] ? [portrait doubleValue] : NAN, NO);
  _wideSplit =
      lemon_adaptive_split([wide isKindOfClass:NSNumber.class] ? [wide doubleValue] : NAN, YES);
  _hud = [UILabel new];
  _hud.font = [[UIFontMetrics metricsForTextStyle:UIFontTextStyleHeadline]
      scaledFontForFont:[UIFont systemFontOfSize:17 weight:UIFontWeightSemibold]
       maximumPointSize:24];
  _hud.adjustsFontForContentSizeCategory = YES;
  _hud.numberOfLines = 0;
  _weather = [UIImageView new];
  _weather.contentMode = UIViewContentModeScaleToFill;
  _weather.layer.contentsRect = CGRectMake(327.0 / 640, 35.0 / 480, 306.0 / 640, 76.0 / 480);
  _weather.layer.magnificationFilter = kCAFilterNearest;
  _weather.isAccessibilityElement = YES;
  _weather.accessibilityLabel = @"Original weather forecast and news";
  _street = [LemonView new];
  _street.portraitPanels = NO;
  _street.preserveAspectRatio = YES;
  _street.sourceRect = CGRectMake(331, 124, 302, 242);
  _street.accessibilityLabel = @"Street view";
  _controls = [LemonView new];
  _controls.portraitPanels = NO;
  _controls.preserveAspectRatio = YES;
  _controls.sourceRect = CGRectMake(0, 0, 320, 480);
  _controls.accessibilityLabel = @"Original game controls";
  _divider = [LemonPaneDivider new];
  [_divider
      addGestureRecognizer:[[UIPanGestureRecognizer alloc] initWithTarget:self
                                                                   action:@selector(resizePanes:)]];
  UITapGestureRecognizer *reset =
      [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(resetSplit)];
  reset.numberOfTapsRequired = 2;
  [_divider addGestureRecognizer:reset];
  __weak LemonDashboardView *weakSelf = self;
  _divider.adjust = ^(CGFloat delta) {
    LemonDashboardView *view = weakSelf;
    if (!view)
      return;
    BOOL wide = view.bounds.size.width > view.bounds.size.height;
    [view cancelGameTouch];
    [view setSplit:(wide ? view.wideSplit : view.portraitSplit) + delta wide:wide save:YES];
  };
  _divider.reset = ^{
    [weakSelf resetSplit];
  };
  for (UIView *view in @[ _hud, _weather, _street, _controls, _divider ])
    [self addSubview:view];
  return self;
}
- (void)setFrameImage:(UIImage *)image {
  _frameImage = image;
  self.weather.image = image;
  self.street.frameImage = image;
  self.controls.frameImage = image;
}
- (void)refresh:(LemonGameState)state {
  NSString *text = [NSString stringWithFormat:@"Cash $%.2f  ·  Price $%.2f / cup",
                                              state.cash_cents / 100.0, state.price_cents / 100.0];
  if ([self.hud.text isEqualToString:text])
    return;
  self.hud.text = text;
  [self setNeedsLayout];
}
- (void)setSplit:(CGFloat)value wide:(BOOL)wide save:(BOOL)save {
  CGFloat ratio = lemon_adaptive_split(value, wide);
  if (wide)
    self.wideSplit = ratio;
  else
    self.portraitSplit = ratio;
  if (save)
    [NSUserDefaults.standardUserDefaults
        setDouble:ratio
           forKey:wide ? @"adaptiveWideSplit" : @"adaptivePortraitSplit"];
  [self setNeedsLayout];
  [self layoutIfNeeded];
}
- (void)resetSplit {
  [self cancelGameTouch];
  [self setSplit:NAN wide:self.bounds.size.width > self.bounds.size.height save:YES];
}
- (void)finishResize {
  if (!self.resizing)
    return;
  self.resizing = NO;
  self.street.userInteractionEnabled = self.controls.userInteractionEnabled = YES;
  [NSUserDefaults.standardUserDefaults
      setDouble:self.dragWide ? self.wideSplit : self.portraitSplit
         forKey:self.dragWide ? @"adaptiveWideSplit" : @"adaptivePortraitSplit"];
}
- (void)resizePanes:(UIPanGestureRecognizer *)gesture {
  if (gesture.state == UIGestureRecognizerStateBegan) {
    [self cancelGameTouch];
    self.dragWide = self.bounds.size.width > self.bounds.size.height;
    self.dragLength =
        self.dragWide ? self.controls.bounds.size.width : self.controls.bounds.size.height;
    self.dragSpan = self.dragWide
                        ? self.bounds.size.width - 16
                        : CGRectGetMaxY(self.controls.frame) - CGRectGetMaxY(self.hud.frame) - 16;
    self.resizing = self.dragSpan > 0;
    self.street.userInteractionEnabled = self.controls.userInteractionEnabled = !self.resizing;
  }
  if (!self.resizing)
    return;
  if (gesture.state == UIGestureRecognizerStateBegan ||
      gesture.state == UIGestureRecognizerStateChanged ||
      gesture.state == UIGestureRecognizerStateEnded) {
    CGPoint delta = [gesture translationInView:self];
    [self setSplit:(self.dragLength - (self.dragWide ? delta.x : delta.y)) / self.dragSpan
              wide:self.dragWide
              save:NO];
  }
  if (gesture.state == UIGestureRecognizerStateEnded ||
      gesture.state == UIGestureRecognizerStateCancelled ||
      gesture.state == UIGestureRecognizerStateFailed)
    [self finishResize];
}
- (void)layoutSubviews {
  [super layoutSubviews];
  CGFloat w = self.bounds.size.width, h = self.bounds.size.height, gap = 16, weatherGap = 8;
  CGFloat heading =
      MIN(h * .2, [self.hud sizeThatFits:CGSizeMake(MAX(0, w - 24), CGFLOAT_MAX)].height + 16);
  self.hud.frame = CGRectMake(12, 0, MAX(0, w - 24), heading);
  BOOL wide = w > h;
  CGFloat available = MAX(0, (wide ? w : h - heading) - gap);
  if (self.resizing && (wide != self.dragWide || fabs(available - self.dragSpan) > .01))
    [self finishResize];
  CGFloat controlsLength =
      lemon_adaptive_controls_length(available, wide ? self.wideSplit : self.portraitSplit);
  CGFloat worldWidth = wide ? available - controlsLength : w;
  CGFloat worldHeight = wide ? h - heading : available - controlsLength;
  CGFloat weatherHeight = MIN(worldHeight * .28, worldWidth * 76 / 306);
  self.weather.frame =
      lemon_fit(CGRectMake(0, 0, 306, 76), CGRectMake(0, heading, worldWidth, weatherHeight));
  self.street.frame = CGRectMake(0, heading + weatherHeight + weatherGap, worldWidth,
                                 MAX(0, worldHeight - weatherHeight - weatherGap));
  self.controls.frame =
      wide ? CGRectMake(worldWidth + gap, heading, controlsLength, MAX(0, h - heading))
           : CGRectMake(0, heading + worldHeight + gap, w, controlsLength);
  self.divider.frame = wide ? CGRectMake(worldWidth, heading, gap, MAX(0, h - heading))
                            : CGRectMake(0, heading + worldHeight, w, gap);
  self.divider.vertical = wide;
  self.divider.accessibilityValue =
      [NSString stringWithFormat:@"%.0f percent controls",
                                 available > 0 ? controlsLength / available * 100 : 50];
  [self.divider setNeedsLayout];
}
- (void)cancelGameTouch {
  [self finishResize];
  [self.street cancelGameTouch];
  [self.controls cancelGameTouch];
  [self endEditing:YES];
}
@end
