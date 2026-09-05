#include "../layout.h"
#include <assert.h>
#include <stdio.h>

static void near(CGFloat a, CGFloat b) { assert(fabs(a - b) < .001); }
int main(void) {
  CGRect sources[] = {CGRectMake(0, 0, 640, 480), lemon_column_source(false),
                      lemon_column_source(true)};
  CGRect screens[] = {{12, 80, 369, 640},
                      {0, 0, 1024, 680},
                      {8, 20, 300, 180},
                      {0, 0, 852, 393},
                      {0, 0, 1080, 440}};
  unsigned screenCount = sizeof(screens) / sizeof(screens[0]);
  for (unsigned i = 0; i < 3; i++) {
    for (unsigned j = 0; j < screenCount; j++) {
      CGRect fit = lemon_fit(sources[i], screens[j]);
      assert(CGRectContainsRect(screens[j], fit));
      CGPoint middle =
          lemon_map_point(CGPointMake(CGRectGetMidX(fit), CGRectGetMidY(fit)), fit, sources[i]);
      near(middle.x, CGRectGetMidX(sources[i]));
      near(middle.y, CGRectGetMidY(sources[i]));
      CGPoint end =
          lemon_map_point(CGPointMake(CGRectGetMaxX(fit), CGRectGetMaxY(fit)), fit, sources[i]);
      near(end.x, CGRectGetMaxX(sources[i]));
      near(end.y, CGRectGetMaxY(sources[i]));
    }
  }
  // The screen's upper half must map to the right column, and its lower half
  // to the left. Include the original top/bottom edges so no buttons are lost.
  for (unsigned i = 0; i < screenCount; i++) {
    CGRect topSpace = lemon_pane_space(screens[i], false);
    CGRect bottomSpace = lemon_pane_space(screens[i], true);
    near(topSpace.size.height, bottomSpace.size.height);
    assert(CGRectGetMaxY(topSpace) <= CGRectGetMinY(bottomSpace));
    assert(CGRectContainsRect(screens[i], topSpace));
    assert(CGRectContainsRect(screens[i], bottomSpace));
    for (unsigned bottom = 0; bottom < 2; bottom++) {
      CGRect source = lemon_column_source(bottom);
      CGRect display = lemon_fit(source, bottom ? bottomSpace : topSpace);
      CGPoint start = lemon_map_point(display.origin, display, source);
      CGPoint end = lemon_map_point(CGPointMake(CGRectGetMaxX(display), CGRectGetMaxY(display)),
                                    display, source);
      near(start.x, bottom ? 0 : 320);
      near(end.x, bottom ? 320 : 640);
      near(start.y, 0);
      near(end.y, 480);
    }
  }
  CGRect fields[] = {{2, 2, 120, 20}, {510, 450, 125, 25}, {30, 295, 140, 20}, {10, 100, 600, 28}};
  for (unsigned i = 0; i < 4; i++) {
    CGRect crop = lemon_text_crop(fields[i]);
    assert(CGRectContainsRect(CGRectMake(0, 0, 640, 480), crop));
    assert(CGRectContainsRect(crop, fields[i]));
  }
  CGPoint invalid = lemon_map_point(CGPointZero, CGRectZero, sources[0]);
  assert(invalid.x == -1 && invalid.y == -1);
  puts("PASS: right-top/left-bottom columns, landscape mapping, keyboard crops, zero-size layout");
}
