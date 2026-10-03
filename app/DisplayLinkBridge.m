#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>
#import <CoreVideo/CoreVideo.h>
#include <mach/mach_time.h>
#include <math.h>
typedef int32_t (*OutputCallback)(void *,const CVTimeStamp *,const CVTimeStamp *,uint64_t,uint64_t *,void *);
@interface StrayDisplayLink : NSObject
@property(nonatomic, strong) CADisplayLink *nativeLink;
@property(nonatomic) OutputCallback callback;
@property(nonatomic) void *context;
@property(nonatomic) uint32_t display;
@end
@implementation StrayDisplayLink
- (void)tick:(CADisplayLink *)link {
    if(!self.callback)return;CVTimeStamp now={0},output={0};now.videoTimeScale=1000000000;
    now.videoTime=(int64_t)llround(link.timestamp*1e9);now.hostTime=mach_absolute_time();now.rateScalar=1;
    now.videoRefreshPeriod=(int64_t)llround((link.targetTimestamp-link.timestamp)*1e9);now.flags=kCVTimeStampVideoHostTimeValid|kCVTimeStampVideoRefreshPeriodValid|kCVTimeStampRateScalarValid;
    output=now;output.videoTime=(int64_t)llround(link.targetTimestamp*1e9);mach_timebase_info_data_t info;mach_timebase_info(&info);
    output.hostTime+=(uint64_t)((link.targetTimestamp-link.timestamp)*1e9*info.denom/info.numer);uint64_t flags=0;
    self.callback((__bridge void *)self,&now,&output,0,&flags,self.context);
}
@end
static StrayDisplayLink *Value(void *link){return (__bridge StrayDisplayLink *)link;}
int32_t CVDisplayLinkCreateWithActiveCGDisplays(void **output){if(!output)return -6661;StrayDisplayLink *link=[StrayDisplayLink new];link.display=1;*output=(void *)CFBridgingRetain(link);return 0;}
int32_t CVDisplayLinkSetCurrentCGDisplay(void *link,uint32_t display){if(!link || display!=1)return -6661;Value(link).display=display;return 0;}
uint32_t CVDisplayLinkGetCurrentCGDisplay(void *link){return link?Value(link).display:0;}
int32_t CVDisplayLinkSetOutputCallback(void *link,OutputCallback callback,void *context){if(!link || !callback)return -6661;Value(link).callback=callback;Value(link).context=context;return 0;}
int32_t CVDisplayLinkStart(void *value){if(!value)return -6661;StrayDisplayLink *link=Value(value);if(!link.callback)return -6661;
    void (^start)(void)=^{if(!link.nativeLink){link.nativeLink=[CADisplayLink displayLinkWithTarget:link selector:@selector(tick:)];[link.nativeLink addToRunLoop:NSRunLoop.mainRunLoop forMode:NSRunLoopCommonModes];}link.nativeLink.paused=NO;};
    if(NSThread.isMainThread)start();else dispatch_sync(dispatch_get_main_queue(),start);return 0;
}
int32_t CVDisplayLinkStop(void *value){if(!value)return -6661;StrayDisplayLink *link=Value(value);void (^stop)(void)=^{[link.nativeLink invalidate];link.nativeLink=nil;};if(NSThread.isMainThread)stop();else dispatch_sync(dispatch_get_main_queue(),stop);return 0;}
double CVDisplayLinkGetActualOutputVideoRefreshPeriod(void *value){if(!value)return 0;CADisplayLink *link=Value(value).nativeLink;return link.duration?:1.0/MAX(1,UIScreen.mainScreen.maximumFramesPerSecond);}
void CVDisplayLinkRelease(void *link){if(link){CVDisplayLinkStop(link);CFRelease(link);}}
