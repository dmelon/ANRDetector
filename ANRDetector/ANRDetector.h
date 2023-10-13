//
//  ANRDetector.h
//
//

@import Foundation;

NS_ASSUME_NONNULL_BEGIN
@class ANRDetector;
@protocol ANRDetectorDelegate <NSObject>
- (void)didDetectIntenseOperationWithDetector:(ANRDetector *)detector
                                     activity:(CFRunLoopActivity)activity
                                        start:(CFTimeInterval)start
                                     duration:(CFTimeInterval)duration
                                        index:(NSInteger)index
                                   isFinished:(BOOL)isFinished;

@end

/// 监听主线程的卡顿的状态，在有 intense 操作时，在非主线程进行 delegate 回调。
/// ANR = Application Not Response
/**
  假设一段在主线程的操作是从 A → B 完整一次 Loop，那么每经过一个 threshold 会进行 delegate 回调，在 B 点前会进行最后一次回调
  A----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------B
  ||                    threshold                    ||                    threshold                    ||                    threshold                    ||                    ...                     ||
                           ↓                                                       ↓                                                      ↓                                            ↓
                     delegate.didDetect                           delegate.didDetect                          delegate.didDetect                 delegate.didFinish
 */
@interface ANRDetector: NSObject

@property (nonatomic, weak) id<ANRDetectorDelegate> delegate;

/// 如果主线程超过 `threshold` 未响应时，会进行 `delegate` 回调, 单位为 milliseconds，默认为 250，必须大于 100
@property (nonatomic, assign) int64_t threshold;

- (void)skipCurrent;
/// 跳过主线程当前 loop 和未来 seconds 时间内、可能的 ANR 事件。
/// 该方法只有在主线程调用时生效。
/// @param seconds 持续时间
- (void)skipCurrentAndSeconds:(CFTimeInterval)seconds;

- (void)tearDown;

@end

NS_ASSUME_NONNULL_END
