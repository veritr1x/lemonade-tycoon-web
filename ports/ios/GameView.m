#import "GameView.h"
#import "layout.h"
#import "../../engine/platform.h"

@interface LemonView ()
@property(nonatomic, strong) UIImageView *topImage, *bottomImage;
@property(nonatomic) CGRect topRect, bottomRect, topSource, bottomSource;
@property(nonatomic) CGRect gestureDisplay, gestureSource;
@property(nonatomic) CGPoint lastGamePoint;
@property(nonatomic) BOOL gameTouchDown, dismissingGesture;
@end

@implementation LemonView
- (instancetype)initWithFrame:(CGRect)frame {
  if ((self = [super initWithFrame:frame])) {
    self.backgroundColor = [UIColor colorWithRed:7 / 255.0
                                           green:20 / 255.0
                                            blue:13 / 255.0
                                           alpha:1];
    _portraitPanels = YES;
    _topImage = [UIImageView new];
    _bottomImage = [UIImageView new];
    for (UIImageView *image in @[ _topImage, _bottomImage ]) {
      image.contentMode = UIViewContentModeScaleToFill;
      image.layer.magnificationFilter = kCAFilterNearest;
      image.layer.minificationFilter = kCAFilterNearest;
      image.layer.masksToBounds = YES;
      image.isAccessibilityElement = NO;
      [self addSubview:image];
    }
    self.multipleTouchEnabled = NO;
    self.isAccessibilityElement = YES;
    self.accessibilityLabel = @"Original game screen";
    self.accessibilityHint =
        @"Use touch to play. VoiceOver navigation within the game is not yet available.";
    self.accessibilityTraits = UIAccessibilityTraitImage;
  }
  return self;
}
- (void)setFrameImage:(UIImage *)image {
  _frameImage = image;
  self.topImage.image = image;
  self.bottomImage.image = image;
}
- (void)setPortraitPanels:(BOOL)enabled {
  _portraitPanels = enabled;
  [self setNeedsLayout];
}
- (void)layoutSubviews {
  [super layoutSubviews];
  CGRect previousTop = self.topRect, previousBottom = self.bottomRect;
  CGRect previousTopSource = self.topSource, previousBottomSource = self.bottomSource;
  CGRect space = CGRectInset(self.bounds, 8, 8);
  BOOL stacked = self.portraitPanels;
  self.bottomImage.hidden = !stacked;
  if (stacked) {
    // Stack the entire right column above the entire left column. Keeping the
    // full height preserves inventory, navigation, and the bottom game buttons.
    self.topSource = lemon_column_source(false);
    self.bottomSource = lemon_column_source(true);
    // Temporarily bring an active field into view above the docked keyboard.
    // Dismissal restores both complete columns without changing game state.
    if (self.textActive && self.isFirstResponder) {
      if (CGRectGetMidX(self.textRect) < 320)
        self.bottomSource = lemon_text_crop(self.textRect);
      else
        self.topSource = lemon_text_crop(self.textRect);
    }
    self.topRect = lemon_fit(self.topSource, lemon_pane_space(space, false));
    self.bottomRect = lemon_fit(self.bottomSource, lemon_pane_space(space, true));
  } else {
    self.topSource = CGRectMake(0, 0, 640, 480);
    self.topRect = lemon_fit(self.topSource, space);
    self.bottomSource = self.bottomRect = CGRectZero;
  }
  self.topImage.frame = self.topRect;
  self.bottomImage.frame = self.bottomRect;
  self.topImage.layer.contentsRect =
      CGRectMake(self.topSource.origin.x / 640, self.topSource.origin.y / 480,
                 self.topSource.size.width / 640, self.topSource.size.height / 480);
  self.bottomImage.layer.contentsRect =
      CGRectMake(self.bottomSource.origin.x / 640, self.bottomSource.origin.y / 480,
                 self.bottomSource.size.width / 640, self.bottomSource.size.height / 480);
  if (!CGRectEqualToRect(previousTop, self.topRect) ||
      !CGRectEqualToRect(previousBottom, self.bottomRect) ||
      !CGRectEqualToRect(previousTopSource, self.topSource) ||
      !CGRectEqualToRect(previousBottomSource, self.bottomSource))
    [self cancelGameTouch];
}
- (void)updateTextActive:(BOOL)active rect:(CGRect)rect {
  self.textActive = active;
  self.textRect = rect;
  [self setNeedsLayout];
  if (active)
    [self becomeFirstResponder];
  else
    [self resignFirstResponder];
}
- (BOOL)canBecomeFirstResponder {
  return self.textActive;
}
- (BOOL)becomeFirstResponder {
  BOOL result = [super becomeFirstResponder];
  [self setNeedsLayout];
  return result;
}
- (BOOL)resignFirstResponder {
  BOOL result = [super resignFirstResponder];
  [self setNeedsLayout];
  return result;
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
- (void)cancelGameTouch {
  if (self.gameTouchDown) {
    lemon_touch(self.lastGamePoint.x, self.lastGamePoint.y, 2);
    self.gameTouchDown = NO;
  }
}
- (void)sendTouch:(NSSet<UITouch *> *)touches phase:(int)phase {
  CGPoint local = [touches.anyObject locationInView:self];
  if (phase == 0) {
    [self cancelGameTouch];
    self.dismissingGesture = NO;
    BOOL bottom = !self.bottomImage.hidden && CGRectContainsPoint(self.bottomRect, local);
    CGRect display = bottom ? self.bottomRect : self.topRect;
    CGRect source = bottom ? self.bottomSource : self.topSource;
    CGPoint point = lemon_map_point(local, display, source);
    BOOL inside = CGRectContainsPoint(display, local);
    if (self.isFirstResponder &&
        (!inside || !CGRectContainsPoint(CGRectInset(self.textRect, -8, -8), point))) {
      self.dismissingGesture = YES;
      [self resignFirstResponder];
      return;
    }
    if (!inside)
      return;
    if (self.textActive && CGRectContainsPoint(CGRectInset(self.textRect, -8, -8), point))
      [self becomeFirstResponder];
    self.gestureDisplay = display;
    self.gestureSource = source;
    self.gameTouchDown = YES;
  }
  if (self.dismissingGesture || !self.gameTouchDown)
    return;
  CGPoint point = lemon_map_point(local, self.gestureDisplay, self.gestureSource);
  // Always deliver release, even after dragging outside the view. Otherwise an
  // original repeat button can remain held across rotation or backgrounding.
  point.x = fmax(0, fmin(639, point.x));
  point.y = fmax(0, fmin(479, point.y));
  self.lastGamePoint = point;
  lemon_touch(point.x, point.y, phase);
  if (phase == 2)
    self.gameTouchDown = NO;
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
  [self cancelGameTouch];
}
@end
