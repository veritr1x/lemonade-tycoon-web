#ifndef LEMON_IOS_LAYOUT_H
#define LEMON_IOS_LAYOUT_H
#include <CoreGraphics/CoreGraphics.h>
#include <math.h>
#include <stdbool.h>

/* Both painting and input use these rectangles. Each portrait pane displays
 * one complete column of the original 640 x 480 surface. */
static inline CGRect lemon_column_source(bool bottom) {
  return CGRectMake(bottom ? 0 : 320, 0, 320, 480);
}
static inline CGRect lemon_pane_space(CGRect space, bool bottom) {
  CGFloat gap = fmin(12, fmax(0, space.size.height));
  CGFloat height = fmax(0, (space.size.height - gap) / 2);
  return CGRectMake(space.origin.x, space.origin.y + (bottom ? height + gap : 0), space.size.width,
                    height);
}
/* The split is the fraction reserved for the original controls. Keep both
 * panes reachable, even on small windows. Portrait and widescreen have their
 * own remembered ratios; missing or invalid preferences use the earlier split. */
static inline CGFloat lemon_adaptive_split(CGFloat ratio, bool wide) {
  return isfinite(ratio) ? fmin(.78, fmax(.25, ratio)) : (wide ? .48 : .52);
}
static inline CGFloat lemon_adaptive_controls_length(CGFloat available, CGFloat ratio) {
  available = fmax(0, available);
  CGFloat minimum = fmin(112, available / 2);
  return fmin(available - minimum, fmax(minimum, available * ratio));
}
static inline CGRect lemon_fit(CGRect source, CGRect space) {
  CGFloat scale =
      fmin(space.size.width / source.size.width, space.size.height / source.size.height);
  scale = fmax(0, scale);
  CGSize size = CGSizeMake(source.size.width * scale, source.size.height * scale);
  return CGRectMake(CGRectGetMidX(space) - size.width / 2, CGRectGetMidY(space) - size.height / 2,
                    size.width, size.height);
}
static inline CGRect lemon_display_rect(CGRect source, CGRect space, bool preserveAspectRatio) {
  return preserveAspectRatio ? lemon_fit(source, space) : space;
}
static inline CGPoint lemon_map_point(CGPoint point, CGRect display, CGRect source) {
  if (display.size.width <= 0 || display.size.height <= 0)
    return CGPointMake(-1, -1);
  return CGPointMake(
      source.origin.x + (point.x - display.origin.x) * source.size.width / display.size.width,
      source.origin.y + (point.y - display.origin.y) * source.size.height / display.size.height);
}
static inline CGRect lemon_text_crop(CGRect text) {
  CGFloat width = fmin(640, fmax(320, text.size.width + 32));
  CGFloat height = fmin(480, fmax(150, text.size.height + 64));
  return CGRectMake(fmax(0, fmin(640 - width, CGRectGetMidX(text) - width / 2)),
                    fmax(0, fmin(480 - height, CGRectGetMidY(text) - height / 2)), width, height);
}
#endif
