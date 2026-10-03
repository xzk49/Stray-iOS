#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>
#include <stdint.h>

const CFStringRef kCGDisplayShowDuplicateLowResolutionModes=CFSTR("kCGDisplayShowDuplicateLowResolutionModes");
static BOOL CursorVisible=YES;
static BOOL CursorAssociated=YES;
static CGPoint CursorPoint;
static NSMutableArray *ReconfigurationCallbacks;
static NSMutableDictionary *FadeReservations;
static uint32_t NextFadeToken=1;
static void Main(void (^block)(void)){if(NSThread.isMainThread)block();else dispatch_sync(dispatch_get_main_queue(),block);}
static CGSize PixelSize(void){CGSize size=UIScreen.mainScreen.currentMode.size;return size;}
static NSDictionary *DisplayMode(void){CGSize size=PixelSize();return @{@"width":@(size.width),@"height":@(size.height),@"refresh":@(UIScreen.mainScreen.maximumFramesPerSecond),@"scale":@(UIScreen.mainScreen.scale)};}
uint32_t CGMainDisplayID(void){return 1;}
CGRect CGDisplayBounds(uint32_t display){return display==1?UIScreen.mainScreen.bounds:CGRectZero;}
size_t CGDisplayPixelsWide(uint32_t display){return display==1?(size_t)PixelSize().width:0;}
size_t CGDisplayPixelsHigh(uint32_t display){return display==1?(size_t)PixelSize().height:0;}
CGSize CGDisplayScreenSize(uint32_t display){return CGSizeZero;} // Physical millimetres are not exposed by UIScreen.
uint32_t CGDisplayVendorNumber(uint32_t display){return 0;} // Unknown, not a fabricated hardware identifier.
uint32_t CGDisplayModelNumber(uint32_t display){return 0;}
uint32_t CGDisplaySerialNumber(uint32_t display){return 0;}
int32_t CGGetActiveDisplayList(uint32_t maximum,uint32_t *displays,uint32_t *count){if(!count)return 1001;*count=displays?MIN(maximum,1):1;if(displays&&maximum)displays[0]=1;return 0;}
void *CGDisplayCopyDisplayMode(uint32_t display){return display==1?(void *)CFBridgingRetain(DisplayMode()):NULL;}
CFArrayRef CGDisplayCopyAllDisplayModes(uint32_t display,CFDictionaryRef options){
    if(display!=1)return NULL;
    // The compatibility display exposes render sizes to the game's graphics
    // menu. Windowed rendering changes the drawable, not the iPhone timing.
    NSMutableArray *modes=[NSMutableArray new];
    for(NSArray *size in @[@[@1280,@720],@[@1600,@900],@[@1920,@1080]])
        [modes addObject:@{@"width":size[0],@"height":size[1],@"refresh":@(UIScreen.mainScreen.maximumFramesPerSecond),@"scale":@1}];
    return CFBridgingRetain(modes);
}
size_t CGDisplayModeGetWidth(void *mode){NSDictionary *d=(__bridge NSDictionary *)mode;return (size_t)([d[@"width"] doubleValue]/[d[@"scale"] doubleValue]);}
size_t CGDisplayModeGetHeight(void *mode){NSDictionary *d=(__bridge NSDictionary *)mode;return (size_t)([d[@"height"] doubleValue]/[d[@"scale"] doubleValue]);}
size_t CGDisplayModeGetPixelWidth(void *mode){return [((__bridge NSDictionary *)mode)[@"width"] unsignedLongValue];}
size_t CGDisplayModeGetPixelHeight(void *mode){return [((__bridge NSDictionary *)mode)[@"height"] unsignedLongValue];}
double CGDisplayModeGetRefreshRate(void *mode){return [((__bridge NSDictionary *)mode)[@"refresh"] doubleValue];}
bool CGDisplayModeIsUsableForDesktopGUI(void *mode){return mode!=NULL;}
void *CGDisplayModeRetain(void *mode){if(mode)CFRetain(mode);return mode;}
void CGDisplayModeRelease(void *mode){if(mode)CFRelease(mode);}
int32_t CGDisplaySetDisplayMode(uint32_t display,void *mode,CFDictionaryRef options){
    if(display!=1 || !mode)return 1001;
    // iOS does not offer arbitrary physical timings. Accept only its current mode.
    NSDictionary *value=(__bridge NSDictionary *)mode;
    return [value isEqual:DisplayMode()]?0:1008;
}
typedef void (*DisplayCallback)(uint32_t,uint32_t,void *);
int32_t CGDisplayRegisterReconfigurationCallback(DisplayCallback callback,void *context){if(!callback)return 1001;@synchronized(ReconfigurationCallbacks){[ReconfigurationCallbacks addObject:@[[NSValue valueWithPointer:callback],[NSValue valueWithPointer:context]]];}return 0;}
int32_t CGDisplayRemoveReconfigurationCallback(DisplayCallback callback,void *context){@synchronized(ReconfigurationCallbacks){NSIndexSet *indexes=[ReconfigurationCallbacks indexesOfObjectsPassingTest:^BOOL(NSArray *v,NSUInteger i,BOOL *stop){return [v[0] pointerValue]==callback && [v[1] pointerValue]==context;}];[ReconfigurationCallbacks removeObjectsAtIndexes:indexes];}return 0;}
int32_t CGAssociateMouseAndMouseCursorPosition(bool associated){CursorAssociated=associated;return 0;}
bool CGCursorIsVisible(void){return CursorVisible;}
int32_t CGDisplayHideCursor(uint32_t display){if(display!=1)return 1001;CursorVisible=NO;return 0;}
int32_t CGDisplayShowCursor(uint32_t display){if(display!=1)return 1001;CursorVisible=YES;return 0;}
int32_t CGWarpMouseCursorPosition(CGPoint point){CursorPoint=point;return 0;} // Logical game cursor; no privileged system pointer warp.
CFDictionaryRef CGSessionCopyCurrentDictionary(void){return CFBridgingRetain(@{@"kCGSessionOnConsoleKey":@YES,@"kCGSessionLoginDoneKey":@YES,@"kCGSessionUserIDKey":@(getuid())});}
int32_t CGAcquireDisplayFadeReservation(float seconds,uint32_t *token){if(!token || seconds<=0 || seconds>15)return 1001;@synchronized(FadeReservations){*token=NextFadeToken++;FadeReservations[@(*token)]=[UIView new];}return 0;}
int32_t CGDisplayFade(uint32_t token,float duration,float start,float end,float red,float green,float blue,uint32_t synchronous){
    UIView *overlay;@synchronized(FadeReservations){overlay=FadeReservations[@(token)];}if(!overlay)return 1001;
    __block BOOL completed=NO;Main(^{UIWindow *window=nil;for(UIWindow *w in UIApplication.sharedApplication.windows)if(w.isKeyWindow){window=w;break;}
        overlay.frame=window.bounds;overlay.backgroundColor=[UIColor colorWithRed:red green:green blue:blue alpha:1];overlay.userInteractionEnabled=NO;
        overlay.alpha=start;[window addSubview:overlay];[UIView animateWithDuration:MAX(0,duration) animations:^{overlay.alpha=end;} completion:^(BOOL finished){completed=YES;}];});
    if(synchronous)while(!completed){if(NSThread.isMainThread)[NSRunLoop.mainRunLoop runMode:NSDefaultRunLoopMode beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.01]];else[NSThread sleepForTimeInterval:0.01];}return 0;
}
int32_t CGReleaseDisplayFadeReservation(uint32_t token){UIView *view;@synchronized(FadeReservations){view=FadeReservations[@(token)];[FadeReservations removeObjectForKey:@(token)];}if(!view)return 1001;Main(^{[view removeFromSuperview];});return 0;}
__attribute__((constructor))static void SetupDisplay(void){ReconfigurationCallbacks=[NSMutableArray new];FadeReservations=[NSMutableDictionary new];
    [NSNotificationCenter.defaultCenter addObserverForName:UIDeviceOrientationDidChangeNotification object:nil queue:NSOperationQueue.mainQueue usingBlock:^(NSNotification *n){NSArray *callbacks;@synchronized(ReconfigurationCallbacks){callbacks=[ReconfigurationCallbacks copy];}for(NSArray *entry in callbacks){DisplayCallback callback=[entry[0] pointerValue];callback(1,1<<8,[entry[1] pointerValue]);}}];
}
