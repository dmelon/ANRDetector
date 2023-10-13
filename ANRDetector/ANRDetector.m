//
//  ANRDetector.m
//
//

#import "ANRDetector.h"
#import <pthread.h>

#if DEBUG
//#define DebugLog
#endif

static void runLoopObserverCallBack(CFRunLoopObserverRef observer, CFRunLoopActivity activity, void *info);

@interface ANRDetector ()
{
  @public pthread_mutex_t _mutex;
  @public CFRunLoopActivity _activity;
  @public CFAbsoluteTime _time; // 一次 ANR 事件的起始时间
  @public NSInteger _index; // 当前被 detected 的序数
  @public CFAbsoluteTime _detectedTime; // 当前被 detected 的时间
  @public CFAbsoluteTime _duration; // 当前被 detected 时，距离 _time 的时间间隔

  @public CFAbsoluteTime _skipDeadline;

  @public dispatch_semaphore_t _semaphore;
  @public CFRunLoopObserverRef _observer;

  int64_t _threshold;
}
@end

@implementation ANRDetector

- (instancetype)init {
  self = [super init];
  if (self) {
    pthread_mutex_init(&self->_mutex, NULL);

    // _duration 在第一次进入到关注的 beforeSources/afterWaiting 时才被第一次有意义地赋值
    self->_duration = -1;
    self->_threshold = 250;
    [self registerObserver];
  }
  return self;
}

- (void)setThreshold:(int64_t)threshold {
  /// 按 60HZ 刷新频率来算，threshold 为 17ms，小于该值不认为有实际意义
  _threshold = MAX(17, threshold);
}

- (int64_t)threshold {
  return _threshold;
}

- (void)skipCurrent {
  [self skipCurrentAndSeconds:0];
}

- (void)skipCurrentAndSeconds:(CFTimeInterval)seconds {
  if (!NSThread.isMainThread || seconds < 0) return;

  CFAbsoluteTime current = CFAbsoluteTimeGetCurrent();

  pthread_mutex_lock(&self->_mutex);
  _duration = -1;
  _skipDeadline = current + MIN(60, seconds);
  pthread_mutex_unlock(&self->_mutex);
}

- (void)tearDown {
  if (NSThread.isMainThread) {
    CFRunLoopRemoveObserver(CFRunLoopGetMain(), self->_observer, kCFRunLoopCommonModes);
    self->_observer = nil;
  } else {
    dispatch_async(dispatch_get_main_queue(), ^{
      CFRunLoopRemoveObserver(CFRunLoopGetMain(), self->_observer, kCFRunLoopCommonModes);
      self->_observer = nil;
    });
  }
}

- (void)dealloc {
  if (self->_observer) {
    NSAssert(NO, @"Apm.ANRDetectoer: tearDown should be called before dealloc");
  }
  pthread_mutex_destroy(&self->_mutex);
}

// 参考：http://www.tanhao.me/code/151113.html/
- (void)registerObserver {
  CFRunLoopObserverContext context = { 0, (__bridge void *)self, NULL, NULL };
  self->_observer = CFRunLoopObserverCreate(kCFAllocatorDefault,
                                            kCFRunLoopAllActivities,
                                            YES,
                                            0,
                                            &runLoopObserverCallBack,
                                            &context);
  CFRunLoopAddObserver(CFRunLoopGetMain(), _observer, kCFRunLoopCommonModes);

  // 在子线程监控时长
  _semaphore = dispatch_semaphore_create(0);

  __typeof__(self) __weak weakSelf = self;
  dispatch_async(dispatch_get_global_queue(0, 0), ^{
    while (YES) {
      __typeof__(self) self = weakSelf;
      if (!self) {
        break;
      }
      
      __unused long st = dispatch_semaphore_wait(self->_semaphore, dispatch_time(DISPATCH_TIME_NOW, self->_threshold * NSEC_PER_MSEC));

      pthread_mutex_lock(&self->_mutex);
      CFAbsoluteTime current = CFAbsoluteTimeGetCurrent();
      if (self->_duration < 0 || current <= self->_skipDeadline) {
        pthread_mutex_unlock(&self->_mutex);
        continue;
      }

      BOOL isFinished = NO;
      CFAbsoluteTime duration = 0.0;
      CFTimeInterval threshold_f = (CFTimeInterval)(self->_threshold) / 1000;
      NSInteger index = 0;
      
      if (self->_duration > threshold_f) {
        isFinished = YES;
        duration = self->_duration;
        index = self->_index + 1;
      } else if (self->_duration == 0 && current - self->_detectedTime > threshold_f) { // 超时了
        index = self->_index;
        self->_detectedTime = current;
        self->_index += 1;
        isFinished = NO;
        duration = current - self->_time;
      }
      pthread_mutex_unlock(&self->_mutex);

      if (duration > 0) {
#ifdef DebugLog
        NSLog(@"ANRDetector: main runloop ANR detected = %lu, duration = %f", self->_activity, duration);
#endif
        [self.delegate didDetectIntenseOperationWithDetector:self
                                                    activity:self->_activity
                                                       start:self->_time + kCFAbsoluteTimeIntervalSince1970
                                                    duration:duration
                                                       index:index
                                                  isFinished:isFinished];
      }
    }
    // NSLog(@"ANRDetector: while(YES) broken");
  });
}

@end

static void runLoopObserverCallBack(CFRunLoopObserverRef observer, CFRunLoopActivity activity, void *info)
{
  CFAbsoluteTime current = CFAbsoluteTimeGetCurrent();

#ifdef DebugLog
  static CFAbsoluteTime last = 0;
  static CFRunLoopActivity lastActivity = 0;
  NSLog(@"ANRDetector: main runloop activity changes = (%lu, %lu), duration = %f", lastActivity, activity, current - last);
  last = current;
  lastActivity = activity;
#endif

  ANRDetector *detector = (__bridge ANRDetector *)info;
  if (activity == kCFRunLoopBeforeSources || activity == kCFRunLoopAfterWaiting) {
    pthread_mutex_lock(&detector->_mutex);
    detector->_activity = activity;
    detector->_time = detector->_detectedTime = current;
    detector->_duration = 0;
    detector->_index = 0;
    pthread_mutex_unlock(&detector->_mutex);

    dispatch_semaphore_t semaphore = detector->_semaphore;
    dispatch_semaphore_signal(semaphore);
  } else if (detector->_duration == 0) {
    pthread_mutex_lock(&detector->_mutex);
    detector->_duration = current - detector->_time;
    pthread_mutex_unlock(&detector->_mutex);

    dispatch_semaphore_t semaphore = detector->_semaphore;
    dispatch_semaphore_signal(semaphore);
  }
}
