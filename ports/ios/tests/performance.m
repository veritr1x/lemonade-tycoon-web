/* Only --benchmark includes this workload. Its separate bundle and save directory
 * make device measurements repeatable without touching a player's careers.
 * Frame timings measure host image delivery, not physical display scanout. */
#import <UIKit/UIKit.h>
#include <mach/mach.h>
#include <pthread.h>
#include <sys/resource.h>
#include <time.h>
#import "../../../engine/platform.h"
#import "../../../engine/game.h"

static UIWindow *window;
static NSMutableArray *results;
static pthread_mutex_t lock = PTHREAD_MUTEX_INITIALIZER;
static BOOL measuring;
static unsigned generated, delivered, polls, displayTicks, intervalCount;
static double lastFrame, intervals[8192];
static double duration = 20;
@protocol LemonPerformanceSettings
- (void)refreshDisplaySettings;
@end

static double now(void) {
  struct timespec t;
  clock_gettime(CLOCK_MONOTONIC, &t);
  return t.tv_sec + t.tv_nsec / 1e9;
}
static double cpuSeconds(void) {
  struct rusage usage;
  getrusage(RUSAGE_SELF, &usage);
  return usage.ru_utime.tv_sec + usage.ru_utime.tv_usec / 1e6 + usage.ru_stime.tv_sec +
         usage.ru_stime.tv_usec / 1e6;
}
static double footprintMiB(void) {
  task_vm_info_data_t info;
  mach_msg_type_number_t count = TASK_VM_INFO_COUNT;
  return task_info(mach_task_self(), TASK_VM_INFO, (task_info_t)&info, &count) == KERN_SUCCESS
             ? info.phys_footprint / 1048576.0
             : -1;
}
void lemon_benchmark_frame(BOOL presentation) {
  pthread_mutex_lock(&lock);
  if (measuring) {
    if (presentation) {
      double time = now();
      if (lastFrame && intervalCount < 8192)
        intervals[intervalCount++] = (time - lastFrame) * 1000;
      lastFrame = time;
      delivered++;
    } else {
      generated++;
    }
  }
  pthread_mutex_unlock(&lock);
}
void lemon_benchmark_poll(void) {
  if (measuring)
    polls++;
}
void lemon_benchmark_display_tick(void) {
  if (measuring)
    displayTicks++;
}
static void later(double seconds, void (^next)(void)) {
  dispatch_after(dispatch_time(DISPATCH_TIME_NOW, seconds * NSEC_PER_SEC),
                 dispatch_get_main_queue(), next);
}
static LemonGameState state(void) {
  LemonGameState s;
  lemon_game_state(&s);
  return s;
}
static void writeReport(NSString *status) {
  NSDictionary *report = @{
    @"result" : status,
    @"device" : UIDevice.currentDevice.model,
    @"os" : UIDevice.currentDevice.systemVersion,
    @"build" : [NSBundle.mainBundle objectForInfoDictionaryKey:@"CFBundleVersion"],
    @"measurements" : results,
    @"frame_metric" : @"Host image delivery intervals; not display scanout",
    @"cpu_metric" : @"Process CPU seconds / wall seconds; 100 percent is one core"
  };
  NSString *directory =
      NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES).firstObject;
  [[NSJSONSerialization dataWithJSONObject:report options:NSJSONWritingPrettyPrinted error:nil]
      writeToFile:[directory stringByAppendingPathComponent:@"performance.json"]
       atomically:YES];
}
static void require(BOOL ok, NSString *message) {
  if (!ok) {
    writeReport(message);
    fprintf(stderr, "FAIL: benchmark: %s\n", message.UTF8String);
    abort();
  }
}
static int compare(const void *a, const void *b) {
  double x = *(const double *)a, y = *(const double *)b;
  return (x > y) - (x < y);
}
static void measure(NSString *name, void (^next)(void)) {
  pthread_mutex_lock(&lock);
  generated = delivered = polls = displayTicks = intervalCount = 0;
  lastFrame = 0;
  measuring = YES;
  pthread_mutex_unlock(&lock);
  double start = now(), cpu = cpuSeconds();
  NSInteger thermal = NSProcessInfo.processInfo.thermalState;
  NSInteger requestedRate = [NSUserDefaults.standardUserDefaults integerForKey:@"frameRate"];
  fprintf(stderr, "BENCHMARK BEGIN %s\n", name.UTF8String);
  later(duration, ^{
    double elapsed = now() - start, used = cpuSeconds() - cpu;
    require(requestedRate == [NSUserDefaults.standardUserDefaults integerForKey:@"frameRate"],
            @"Frame rate changed during a measurement; repeat the workload");
    pthread_mutex_lock(&lock);
    measuring = NO;
    qsort(intervals, intervalCount, sizeof(double), compare);
    NSMutableDictionary *row = [@{
      @"phase" : name,
      @"seconds" : @(elapsed),
      @"cpu_percent_one_core" : @(used / elapsed * 100),
      @"footprint_mib" : @(footprintMiB()),
      @"generated_frames" : @(generated),
      @"delivered_frames" : @(delivered),
      @"host_polls" : @(polls),
      @"display_link_fps" : @(displayTicks / elapsed),
      @"requested_fps" : @([NSUserDefaults.standardUserDefaults integerForKey:@"frameRate"]),
      @"screen_maximum_fps" : @(window.screen.maximumFramesPerSecond),
      @"delivered_fps" : @(delivered / elapsed),
      @"thermal_start" : @(thermal),
      @"thermal_end" : @(NSProcessInfo.processInfo.thermalState),
      @"low_power_mode" : @(NSProcessInfo.processInfo.lowPowerModeEnabled),
      @"brightness" : @(window.screen.brightness),
      @"battery_state" : @(UIDevice.currentDevice.batteryState),
      @"can_manage_end" : @(state().can_manage)
    } mutableCopy];
    if (intervalCount) {
      row[@"delivery_p50_ms"] = @(intervals[(intervalCount - 1) / 2]);
      row[@"delivery_p95_ms"] = @(intervals[(intervalCount - 1) * 95 / 100]);
      row[@"delivery_max_ms"] = @(intervals[intervalCount - 1]);
    }
    pthread_mutex_unlock(&lock);
    [results addObject:row];
    writeReport(@"running");
    fprintf(stderr, "BENCHMARK END %s CPU=%.2f%% FPS=%.2f polls=%u\n", name.UTF8String,
            used / elapsed * 100, delivered / elapsed, polls);
    next();
  });
}
static void selectRate(unsigned rate) {
  [NSUserDefaults.standardUserDefaults setInteger:rate forKey:@"frameRate"];
  [(id<LemonPerformanceSettings>)window.rootViewController refreshDisplaySettings];
}
static void measureBothRates(NSString *phase, void (^next)(void)) {
  selectRate(60);
  later(1, ^{
    measure(phase, ^{
      selectRate(120);
      later(1, ^{
        measure([phase stringByAppendingString:@"_120"], ^{
          selectRate(60);
          later(1, next);
        });
      });
    });
  });
}
static void tap(int x, int y, void (^next)(void)) {
  lemon_touch(x, y, 0);
  later(.10, ^{
    lemon_touch(x, y, 2);
    later(.30, next);
  });
}
static void buy(unsigned ingredient, void (^next)(void)) {
  if (ingredient == 4) {
    next();
    return;
  }
  tap(50 + ingredient * 60, 240, ^{
    tap(244, 284, ^{
      buy(ingredient + 1, next);
    });
  });
}
static void togglePause(void) {
  UIButton *button = [window.rootViewController valueForKey:@"pauseButton"];
  [button sendActionsForControlEvents:UIControlEventTouchUpInside];
}
void lemon_benchmark_prepare(void) {
  NSString *bundle = NSBundle.mainBundle.bundleIdentifier;
  NSCAssert([bundle hasSuffix:@".benchmark"], @"Benchmarks require an isolated bundle");
  [NSUserDefaults.standardUserDefaults removePersistentDomainForName:bundle];
  [NSUserDefaults.standardUserDefaults setInteger:60 forKey:@"frameRate"];
  NSString *directory =
      NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES).firstObject;
  for (NSString *file in [NSFileManager.defaultManager contentsOfDirectoryAtPath:directory
                                                                           error:nil])
    [NSFileManager.defaultManager removeItemAtPath:[directory stringByAppendingPathComponent:file]
                                             error:nil];
  UIDevice.currentDevice.batteryMonitoringEnabled = YES;
}
void lemon_benchmark_start(UIWindow *target) {
  window = target;
  // Programmatic button actions still work. Ignore physical touches so an
  // accidental tap cannot change a rate, pause state, or purchase mid-measurement.
  window.userInteractionEnabled = NO;
  results = [NSMutableArray new];
  later(6, ^{
    require(!state().loaded, @"Expected a fresh main menu");
    measure(@"menu", ^{
      tap(54, 198, ^{
        tap(72, 280, ^{
          for (const char *s = "BENCHMARK"; *s; s++)
            lemon_key(*s);
          lemon_key(13);
          later(1, ^{
            require(state().loaded && state().cash_cents == 4000, @"Career creation failed");
            measureBothRates(@"adaptive_idle", ^{
              togglePause();
              later(1, ^{
                measure(@"paused", ^{
                  togglePause();
                  tap(294, 80, ^{
                    buy(0, ^{
                      tap(280, 412, ^{
                        tap(440, 268, ^{
                          require(state().cash_cents == 2840, @"Original purchase failed");
                          tap(272, 468, ^{
                            require(!state().can_manage, @"Selling did not start");
                            measureBothRates(@"selling", ^{
                              writeReport(@"passed");
                              window.userInteractionEnabled = YES;
                              fprintf(stderr, "PASS: performance workload complete\n");
                              lemon_request_quit();
                            });
                          });
                        });
                      });
                    });
                  });
                });
              });
            });
          });
        });
      });
    });
  });
}
