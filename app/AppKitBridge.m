#import "AppKitBridge.h"
#import "TouchGamepad.h"
#import <Metal/Metal.h>
#import <objc/message.h>
#import <objc/runtime.h>
#include <stdarg.h>
#include <unistd.h>

#include "AppKitConstants.inc"
NSApplication *NSApp;
static __weak UIWindow *HostWindow;
static NSMutableDictionary *Runtime;
static NSMutableArray *Monitors;
static CGPoint MouseLocation;
static NSUInteger MouseButtons;
static NSUInteger ModifierFlags;

static void Main(void (^block)(void)) {
    if (NSThread.isMainThread) block(); else dispatch_sync(dispatch_get_main_queue(), block);
}
static void Note(NSString *name, id value) {
    @synchronized(Runtime) { Runtime[name] = value; }
    NSLog(@"STRAY_APPKIT %@ %@", name, value);
}
void StrayAppKitBindHostWindow(UIWindow *window) { HostWindow = window; StrayInstallTouchGamepad(); }
NSDictionary *StrayAppKitRuntimeReport(void) { @synchronized(Runtime) { return [Runtime copy]; } }

@interface StrayCanvas : UIView
@property(nonatomic, weak) NSView *cocoaView;
@property(nonatomic) CGPoint lastTouch;
@end
@implementation StrayCanvas
- (BOOL)canBecomeFirstResponder { return YES; }
- (void)layoutSubviews {
    [super layoutSubviews];
    CALayer *layer=self.cocoaView.layer;
    if(!layer)return;
    CGRect viewport=self.bounds;
    if([layer isKindOfClass:CAMetalLayer.class]){
        CGSize image=((CAMetalLayer *)layer).drawableSize;
        if(!image.width || !image.height)image=self.cocoaView.bounds.size;
        if(image.width>0 && image.height>0){
            CGFloat scale=MIN(viewport.size.width/image.width,viewport.size.height/image.height);
            CGSize size=CGSizeMake(image.width*scale,image.height*scale);
            viewport=CGRectMake(CGRectGetMidX(self.bounds)-size.width/2,CGRectGetMidY(self.bounds)-size.height/2,size.width,size.height);
        }
    }
    [CATransaction begin];[CATransaction setDisableActions:YES];layer.frame=viewport;[CATransaction commit];
}
- (void)emitTouch:(UITouch *)touch type:(NSUInteger)type {
    NSWindow *window = self.cocoaView.window;
    if (!window) return;
    CGPoint p = [touch locationInView:self];
    CGRect viewport=[self.cocoaView.layer isKindOfClass:CAMetalLayer.class]?self.cocoaView.layer.frame:self.bounds;
    if(type==1 && !CGRectContainsPoint(viewport,p))return;
    p.x-=viewport.origin.x;p.y-=viewport.origin.y;
    CGFloat sx = viewport.size.width ? self.cocoaView.bounds.size.width / viewport.size.width : 1;
    CGFloat sy = viewport.size.height ? self.cocoaView.bounds.size.height / viewport.size.height : 1;
    NSEvent *event = [NSEvent new];
    event.type = type; event.windowNumber = window.windowNumber;
    event.locationInWindow = CGPointMake(p.x * sx, self.cocoaView.bounds.size.height - p.y * sy);
    event.timestamp = touch.timestamp; event.clickCount = touch.tapCount;
    event.deltaX = (p.x - self.lastTouch.x) * sx; event.deltaY = (p.y - self.lastTouch.y) * sy;
    self.lastTouch = p; MouseLocation = event.locationInWindow;
    MouseButtons = type == 2 ? 0 : 1;
    [NSApp postEvent:event atStart:NO];
}
- (void)touchesBegan:(NSSet *)touches withEvent:(UIEvent *)event { [self becomeFirstResponder]; [self emitTouch:touches.anyObject type:1]; }
- (void)touchesMoved:(NSSet *)touches withEvent:(UIEvent *)event { [self emitTouch:touches.anyObject type:6]; }
- (void)touchesEnded:(NSSet *)touches withEvent:(UIEvent *)event { [self emitTouch:touches.anyObject type:2]; }
- (void)touchesCancelled:(NSSet *)touches withEvent:(UIEvent *)event { [self emitTouch:touches.anyObject type:2]; }
- (void)emitPresses:(NSSet<UIPress *> *)presses down:(BOOL)down {
    NSDictionary *codes = @{@"a":@0,@"s":@1,@"d":@2,@"f":@3,@"h":@4,@"g":@5,@"z":@6,@"x":@7,
        @"c":@8,@"v":@9,@"b":@11,@"q":@12,@"w":@13,@"e":@14,@"r":@15,@"y":@16,@"t":@17,
        @"1":@18,@"2":@19,@"3":@20,@"4":@21,@"6":@22,@"5":@23,@"9":@25,@"7":@26,@"8":@28,@"0":@29,
        @"o":@31,@"u":@32,@"i":@34,@"p":@35,@"l":@37,@"j":@38,@"k":@40,@"n":@45,@"m":@46,@" ":@49};
    for (UIPress *press in presses) {
        UIKey *key = press.key; if (!key) continue;
        NSNumber *code = codes[key.charactersIgnoringModifiers.lowercaseString];
        switch (key.keyCode) {
            case UIKeyboardHIDUsageKeyboardReturnOrEnter: code=@36; break;
            case UIKeyboardHIDUsageKeyboardEscape: code=@53; break;
            case UIKeyboardHIDUsageKeyboardDeleteOrBackspace: code=@51; break;
            case UIKeyboardHIDUsageKeyboardTab: code=@48; break;
            case UIKeyboardHIDUsageKeyboardLeftArrow: code=@123; break;
            case UIKeyboardHIDUsageKeyboardRightArrow: code=@124; break;
            case UIKeyboardHIDUsageKeyboardDownArrow: code=@125; break;
            case UIKeyboardHIDUsageKeyboardUpArrow: code=@126; break;
            default: break;
        }
        if (!code) continue;
        NSEvent *event = [NSEvent new]; event.type = down ? 10 : 11; event.keyCode = code.unsignedShortValue;
        event.characters=key.characters; event.charactersIgnoringModifiers=key.charactersIgnoringModifiers;
        event.modifierFlags=key.modifierFlags; ModifierFlags=event.modifierFlags;
        event.timestamp=NSProcessInfo.processInfo.systemUptime; event.windowNumber=self.cocoaView.window.windowNumber;
        [NSApp postEvent:event atStart:NO];
    }
}
- (void)pressesBegan:(NSSet *)presses withEvent:(UIPressesEvent *)event { [self emitPresses:presses down:YES]; }
- (void)pressesEnded:(NSSet *)presses withEvent:(UIPressesEvent *)event { [self emitPresses:presses down:NO]; }
@end

@implementation NSView
- (BOOL)inLiveResize { return NO; } // UIKit fullscreen views have no AppKit resize-drag session.
- (instancetype)init { return [self initWithFrame:CGRectZero]; }
- (instancetype)initWithFrame:(CGRect)frame {
    if ((self=[super init])) {
        _frame=frame; _bounds=(CGRect){CGPointZero,frame.size}; _subviews=[NSMutableArray new];
        Main(^{ StrayCanvas *view=[[StrayCanvas alloc] initWithFrame:frame]; view.cocoaView=self;
            view.backgroundColor=UIColor.blackColor; self.nativeView=view; });
    }
    return self;
}
- (CALayer *)makeBackingLayer { return [CALayer layer]; }
- (void)setWantsLayer:(BOOL)value { _wantsLayer=value; if(value && !_layer) [self setLayer:[self makeBackingLayer]]; }
- (void)setLayer:(CALayer *)layer {
    if([layer isKindOfClass:CAMetalLayer.class])layer.name=@"StrayGuestMetalLayer";
    Main(^{ [self->_layer removeFromSuperlayer]; self->_layer=layer;
        layer.frame=self.nativeView.bounds; layer.contentsScale=UIScreen.mainScreen.scale;
        [self.nativeView.layer addSublayer:layer];[self.nativeView setNeedsLayout]; });
    Note(@"layer_class",NSStringFromClass(layer.class));
}
- (void)setFrame:(CGRect)frame {
    _frame=frame; _bounds.size=frame.size;
    Main(^{ self.nativeView.frame=frame; self.layer.frame=self.nativeView.bounds; });
    if (_postsFrameChangedNotifications) [NSNotificationCenter.defaultCenter postNotificationName:NSViewFrameDidChangeNotification object:self];
}
- (void)setFrameSize:(CGSize)size { [self setFrame:(CGRect){_frame.origin,size}]; }
- (void)setFrameOrigin:(CGPoint)origin { [self setFrame:(CGRect){origin,_frame.size}]; }
- (void)setBounds:(CGRect)bounds { _bounds=bounds; if(_postsBoundsChangedNotifications) [NSNotificationCenter.defaultCenter postNotificationName:NSViewBoundsDidChangeNotification object:self]; }
- (void)setBoundsSize:(CGSize)size { self.bounds=(CGRect){_bounds.origin,size}; }
- (void)setHidden:(BOOL)hidden { _hidden=hidden; Main(^{self.nativeView.hidden=hidden;}); }
- (BOOL)isHidden { return _hidden; }
- (BOOL)isFlipped { return NO; }
- (BOOL)isOpaque { return self.nativeView.opaque; }
- (BOOL)acceptsFirstResponder { return YES; }
- (BOOL)becomeFirstResponder { Main(^{[self.nativeView becomeFirstResponder];}); return YES; }
- (BOOL)resignFirstResponder { Main(^{[self.nativeView resignFirstResponder];}); return YES; }
- (void)setWindow:(NSWindow *)window { _window=window; for(NSView *v in self.subviews)v.window=window; }
- (void)addSubview:(NSView *)view { [view removeFromSuperview]; [_subviews addObject:view]; view.superview=self; view.window=self.window;
    Main(^{[self.nativeView addSubview:view.nativeView];}); }
- (void)removeFromSuperview { [self.superview.subviews removeObject:self]; self.superview=nil; Main(^{[self.nativeView removeFromSuperview];}); }
- (CGRect)convertRect:(CGRect)rect toView:(NSView *)view { __block CGRect result; Main(^{result=[self.nativeView convertRect:rect toView:view.nativeView];});return result; }
- (CGRect)convertRect:(CGRect)rect fromView:(NSView *)view { __block CGRect result; Main(^{result=[self.nativeView convertRect:rect fromView:view.nativeView];});return result; }
- (CGPoint)convertPoint:(CGPoint)point toView:(NSView *)view { return [self convertRect:(CGRect){point,CGSizeZero} toView:view].origin; }
- (CGPoint)convertPoint:(CGPoint)point fromView:(NSView *)view { return [self convertRect:(CGRect){point,CGSizeZero} fromView:view].origin; }
- (CGRect)convertRectToBacking:(CGRect)rect { CGFloat s=self.window.backingScaleFactor; return CGRectMake(rect.origin.x*s,rect.origin.y*s,rect.size.width*s,rect.size.height*s); }
- (CGRect)convertRectFromBacking:(CGRect)rect { CGFloat s=self.window.backingScaleFactor?:1; return CGRectMake(rect.origin.x/s,rect.origin.y/s,rect.size.width/s,rect.size.height/s); }
- (void)setNeedsDisplay:(BOOL)display { Main(^{if(display)[self.nativeView setNeedsDisplay];}); }
- (void)display { Main(^{[self.nativeView.layer displayIfNeeded];}); }
- (void)displayIfNeeded { [self display]; }
- (void)registerForDraggedTypes:(NSArray *)types { self.nativeView.userInteractionEnabled=YES; }
- (void)unregisterDraggedTypes {}
- (void)viewWillMoveToWindow:(id)window {}
- (void)viewDidMoveToWindow {}
- (void)mouseDown:(id)event {}
- (void)mouseUp:(id)event {}
- (void)mouseMoved:(id)event {}
- (void)mouseDragged:(id)event {}
- (void)keyDown:(id)event {}
- (void)keyUp:(id)event {}
- (void)flagsChanged:(id)event {}
@end

@implementation NSScreen
+ (instancetype)mainScreen { static NSScreen *s; static dispatch_once_t once;dispatch_once(&once,^{s=[self new];});return s; }
+ (NSArray *)screens { return @[[self mainScreen]]; }
- (CGRect)frame { return UIScreen.mainScreen.bounds; }
- (CGRect)visibleFrame { return self.frame; }
- (CGFloat)backingScaleFactor { return UIScreen.mainScreen.scale; }
- (NSDictionary *)deviceDescription { return @{@"NSScreenNumber":@1,@"NSDeviceSize":[NSValue valueWithCGSize:self.frame.size],@"NSDeviceResolution":[NSValue valueWithCGSize:CGSizeMake(72,72)]}; }
- (NSInteger)maximumFramesPerSecond { return UIScreen.mainScreen.maximumFramesPerSecond; }
- (BOOL)canRepresentDisplayGamut:(NSInteger)gamut { return gamut<=1 || UIScreen.mainScreen.traitCollection.displayGamut==UIDisplayGamutP3; }
@end

@implementation NSWindow
- (void)disableSnapshotRestoration { self.restorable=NO; }
// UE4's local monitor already defers these events to its engine. Its text view
// also calls the window's default NSResponder endpoints for window ordering.
- (void)mouseDown:(NSEvent *)event { if(!self.isKeyWindow)[self makeKeyAndOrderFront:nil]; }
- (void)mouseUp:(NSEvent *)event {}
- (void)mouseDragged:(NSEvent *)event {}
- (void)mouseMoved:(NSEvent *)event {}
- (void)setIgnoresMouseEvents:(BOOL)ignore { _ignoresMouseEvents=ignore;Main(^{self.nativeWindow.userInteractionEnabled=!ignore;}); }
+ (NSInteger)windowNumberAtPoint:(CGPoint)point belowWindowWithWindowNumber:(NSInteger)number {
    BOOL below=number==0;
    for(NSWindow *window in [NSApp.windows reverseObjectEnumerator]){
        if(!below){if(window.windowNumber==number)below=YES;continue;}
        if(window.visible && !window.ignoresMouseEvents && CGRectContainsPoint(window.frame,point))return window.windowNumber;
    }
    return 0;
}
- (instancetype)initWithContentRect:(CGRect)rect styleMask:(NSUInteger)style backing:(NSUInteger)backing defer:(BOOL)defer {
    if ((self=[super init])) {
        _frame=rect; _styleMask=style; _alphaValue=1; _minSize=CGSizeMake(1,1);_maxSize=CGSizeMake(CGFLOAT_MAX,CGFLOAT_MAX);
        _windowNumber=(NSInteger)NSApp.windows.count+1;
        Main(^{ UIWindow *w=HostWindow.windowScene?[[UIWindow alloc] initWithWindowScene:HostWindow.windowScene]:[[UIWindow alloc] initWithFrame:UIScreen.mainScreen.bounds];
            w.frame=UIScreen.mainScreen.bounds; w.rootViewController=[UIViewController new];w.rootViewController.view.backgroundColor=UIColor.blackColor;
            self.nativeWindow=w; });
        [NSApp.windows addObject:self];
        self.contentView=[[NSView alloc] initWithFrame:(CGRect){CGPointZero,rect.size}];
        Note(@"window_created",@YES);
    }
    return self;
}
- (instancetype)initWithContentRect:(CGRect)rect styleMask:(NSUInteger)style backing:(NSUInteger)backing defer:(BOOL)defer screen:(NSScreen *)screen { return [self initWithContentRect:rect styleMask:style backing:backing defer:defer]; }
- (void)setContentView:(NSView *)view {
    Main(^{[self->_contentView.nativeView removeFromSuperview]; self->_contentView=view; view.window=self;
        view.nativeView.frame=self.nativeWindow.rootViewController.view.bounds;
        view.nativeView.autoresizingMask=UIViewAutoresizingFlexibleWidth|UIViewAutoresizingFlexibleHeight;
        view.layer.frame=view.nativeView.bounds;
        [self.nativeWindow.rootViewController.view addSubview:view.nativeView]; });
}
- (NSScreen *)screen { return NSScreen.mainScreen; }
- (CGFloat)backingScaleFactor { return self.screen.backingScaleFactor; }
- (CGRect)frameRectForContentRect:(CGRect)rect { return rect; }
- (CGRect)contentRectForFrameRect:(CGRect)rect { return rect; }
+ (CGRect)frameRectForContentRect:(CGRect)rect styleMask:(NSUInteger)style { return rect; }
- (void)setFrame:(CGRect)rect display:(BOOL)display { self.frame=rect;self.contentView.frame=(CGRect){CGPointZero,rect.size};
    Main(^{self.contentView.nativeView.frame=self.nativeWindow.rootViewController.view.bounds;self.contentView.layer.frame=self.contentView.nativeView.bounds;});
    [NSNotificationCenter.defaultCenter postNotificationName:NSWindowDidResizeNotification object:self]; }
- (void)setFrameOrigin:(CGPoint)origin { self.frame=(CGRect){origin,self.frame.size}; }
- (void)setContentSize:(CGSize)size { [self setFrame:(CGRect){self.frame.origin,size} display:YES]; }
- (void)orderFront:(id)sender { [self makeKeyAndOrderFront:sender]; }
- (void)makeKeyAndOrderFront:(id)sender { self.visible=YES;NSApp.keyWindow=self;NSApp.mainWindow=self;
    Main(^{[self.nativeWindow makeKeyAndVisible];[self.contentView.nativeView setNeedsLayout];[self.contentView.nativeView layoutIfNeeded];[self.contentView.nativeView becomeFirstResponder];
        if(self.contentView.bounds.size.width>=640)StrayAttachTouchGamepad(self.nativeWindow,self.contentView.nativeView);
        Note(@"presentation_geometry",@{@"native":NSStringFromCGRect(self.contentView.nativeView.bounds),@"guest":NSStringFromCGRect(self.contentView.bounds),@"layer":NSStringFromCGRect(self.contentView.layer.frame)});});Note(@"window_visible",@YES); }
- (void)makeMainWindow { NSApp.mainWindow=self; }
- (void)makeKeyWindow { NSApp.keyWindow=self; }
- (void)orderWindow:(NSInteger)ordering relativeTo:(NSInteger)number { if(ordering<0)[self orderOut:nil];else[self orderFront:nil]; }
- (void)orderOut:(id)sender { self.visible=NO;Main(^{self.nativeWindow.hidden=YES;}); }
- (void)close { [self orderOut:nil]; [NSApp.windows removeObject:self]; }
- (BOOL)isVisible { return self.visible; }
- (BOOL)isKeyWindow { return NSApp.keyWindow==self; }
- (BOOL)isMainWindow { return NSApp.mainWindow==self; }
- (BOOL)isOnActiveSpace { return self.visible; }
- (BOOL)isZoomed { return self.zoomed; }
- (BOOL)isMiniaturized { return self.miniaturized; }
- (void)miniaturize:(id)sender { self.miniaturized=YES;[self orderOut:sender]; }
- (void)deminiaturize:(id)sender { self.miniaturized=NO;[self orderFront:sender]; }
- (void)zoom:(id)sender { self.zoomed=!self.zoomed;[self setFrame:self.screen.frame display:YES]; }
- (BOOL)canBecomeKeyWindow { return YES; }
- (BOOL)canBecomeMainWindow { return YES; }
- (BOOL)makeFirstResponder:(id)responder { self.firstResponder=responder;Main(^{[self.contentView.nativeView becomeFirstResponder];});return YES; }
- (void)setAlphaValue:(CGFloat)value { _alphaValue=value;Main(^{self.nativeWindow.alpha=value;}); }
- (void)setBackgroundColor:(id)color { _backgroundColor=color; Main(^{if([color isKindOfClass:UIColor.class])self.nativeWindow.backgroundColor=color;}); }
- (id)standardWindowButton:(NSUInteger)button { return nil; } // iOS windows have no titlebar controls.
- (void)registerForDraggedTypes:(NSArray *)types { [self.contentView registerForDraggedTypes:types]; }
- (void)invalidateShadow {}
- (void)disableCursorRects {}
- (void)enableCursorRects {}
- (CGPoint)convertPointToScreen:(CGPoint)p { return CGPointMake(p.x+self.frame.origin.x,p.y+self.frame.origin.y); }
- (CGPoint)convertPointFromScreen:(CGPoint)p { return CGPointMake(p.x-self.frame.origin.x,p.y-self.frame.origin.y); }
- (CGRect)convertRectToScreen:(CGRect)r { r.origin=[self convertPointToScreen:r.origin];return r; }
- (CGRect)convertRectFromScreen:(CGRect)r { r.origin=[self convertPointFromScreen:r.origin];return r; }
- (CGRect)convertRectToBacking:(CGRect)r { return [self.contentView convertRectToBacking:r]; }
- (CGRect)convertRectFromBacking:(CGRect)r { return [self.contentView convertRectFromBacking:r]; }
- (CGPoint)mouseLocationOutsideOfEventStream { return MouseLocation; }
@end

@interface StrayMonitor : NSObject
@property(nonatomic) uint64_t mask;
@property(nonatomic, copy) NSEvent *(^local)(NSEvent *);
@property(nonatomic, copy) void (^global)(NSEvent *);
@end
@implementation StrayMonitor @end
@implementation NSEvent
- (NSWindow *)window { return [NSApp windowWithWindowNumber:self.windowNumber]; }
+ (id)addLocalMonitorForEventsMatchingMask:(uint64_t)mask handler:(NSEvent *(^)(NSEvent *))handler { StrayMonitor *m=[StrayMonitor new];m.mask=mask;m.local=handler;@synchronized(Monitors){[Monitors addObject:m];}return m; }
+ (id)addGlobalMonitorForEventsMatchingMask:(uint64_t)mask handler:(void (^)(NSEvent *))handler { StrayMonitor *m=[StrayMonitor new];m.mask=mask;m.global=handler;@synchronized(Monitors){[Monitors addObject:m];}return m; }
+ (void)removeMonitor:(id)monitor { @synchronized(Monitors){[Monitors removeObject:monitor];} }
+ (CGPoint)mouseLocation { return MouseLocation; }
+ (NSUInteger)pressedMouseButtons { return MouseButtons; }
+ (NSUInteger)modifierFlags { return ModifierFlags; }
+ (void)setMouseCoalescingEnabled:(BOOL)enabled { Note(@"mouse_coalescing",@(enabled)); }
- (BOOL)hasPreciseScrollingDeltas { return YES; }
- (BOOL)isDirectionInvertedFromDevice { return NO; }
- (float)pressure { return MouseButtons?1:0; }
+ (instancetype)otherEventWithType:(NSUInteger)type location:(CGPoint)point modifierFlags:(NSUInteger)flags timestamp:(NSTimeInterval)time windowNumber:(NSInteger)number context:(id)context subtype:(short)subtype data1:(NSInteger)data1 data2:(NSInteger)data2 {
    NSEvent *event=[self new];event.type=type;event.locationInWindow=point;event.modifierFlags=flags;event.timestamp=time;
    event.windowNumber=number;event.subtype=subtype;event.data1=data1;event.data2=data2;return event;
}
@end

@implementation NSApplication
+ (instancetype)sharedApplication { static dispatch_once_t once;dispatch_once(&once,^{ NSApp=[self new];NSApp.windows=[NSMutableArray new];NSApp.events=[NSMutableArray new];});return NSApp; }
- (void)run { self.running=YES;Note(@"application_run",@YES);
    Main(^{id delegate=self.delegate;SEL selector=NSSelectorFromString(@"applicationDidFinishLaunching:");
        if([delegate respondsToSelector:selector])((void(*)(id,SEL,id))objc_msgSend)(delegate,selector,[NSNotification notificationWithName:@"NSApplicationDidFinishLaunchingNotification" object:self]);});
    while(self.running){ @autoreleasepool{
        // AppKit's native run loop dispatches posted NSEvents on the main
        // thread. UIKit supplies the run loop here; preserve that dispatch
        // so UE4's existing local event monitor receives touch and key input.
        Main(^{for(unsigned i=0;i<256;i++){
            NSEvent *event=[self nextEventMatchingMask:UINT64_MAX untilDate:NSDate.distantPast inMode:NSDefaultRunLoopMode dequeue:YES];
            if(!event)break;[self sendEvent:event];
        }});
        [NSThread sleepForTimeInterval:0.01];
    }}
}
- (void)stop:(id)sender { self.running=NO; }
- (void)terminate:(id)sender { [self stop:sender];Note(@"termination_requested",@YES); }
- (void)replyToApplicationShouldTerminate:(BOOL)terminate { if(terminate)[self terminate:nil]; }
- (BOOL)isActive { return UIApplication.sharedApplication.applicationState==UIApplicationStateActive; }
- (BOOL)isHidden { return UIApplication.sharedApplication.applicationState==UIApplicationStateBackground; }
- (BOOL)isRunning { return self.running; }
- (void)activateIgnoringOtherApps:(BOOL)ignore { Main(^{[self.keyWindow.nativeWindow makeKeyAndVisible];}); }
- (BOOL)setActivationPolicy:(NSInteger)policy { objc_setAssociatedObject(self,@selector(activationPolicy),@(policy),OBJC_ASSOCIATION_RETAIN_NONATOMIC);return YES; }
- (NSInteger)activationPolicy { return [objc_getAssociatedObject(self,@selector(activationPolicy)) integerValue]; }
- (void)finishLaunching {}
- (void)preventWindowOrdering {} // UIKit has no click-driven desktop window ordering.
- (void)addWindowsItem:(NSWindow *)window title:(NSString *)title filename:(BOOL)filename { window.title=title; }
- (NSArray *)orderedWindows { return [self.windows copy]; }
- (NSWindow *)windowWithWindowNumber:(NSInteger)number { for(NSWindow *w in self.windows)if(w.windowNumber==number)return w;return nil; }
- (void)postEvent:(NSEvent *)event atStart:(BOOL)atStart { @synchronized(self.events){if(atStart)[self.events insertObject:event atIndex:0];else[self.events addObject:event];} }
- (NSEvent *)nextEventMatchingMask:(uint64_t)mask untilDate:(NSDate *)date inMode:(NSString *)mode dequeue:(BOOL)dequeue {
    @synchronized(self.events){for(NSUInteger i=0;i<self.events.count;i++){NSEvent *e=self.events[i];if(e.type<64 && (mask&(1ULL<<e.type))){if(dequeue)[self.events removeObjectAtIndex:i];return e;}}}return nil;
}
- (void)sendEvent:(NSEvent *)event { NSArray *monitors;@synchronized(Monitors){monitors=[Monitors copy];}
    static unsigned observed; if(observed++<12)Note(@"input_dispatch",@{@"type":@(event.type),@"window":@(event.windowNumber),@"point":NSStringFromCGPoint(event.locationInWindow),@"key":@(event.keyCode),@"monitors":@(monitors.count)});
    // Global AppKit monitors observe other applications, never the receiving
    // app's own events. Calling both caused each UE4 key press to be deferred
    // twice (for example, one Down skipped two menu rows).
    for(StrayMonitor *m in monitors){if(event.type>=64 || !(m.mask&(1ULL<<event.type)))continue;if(m.local){event=m.local(event);if(!event)return;}}
    NSView *view=event.window.contentView;NSDictionary *selectors=@{@1:@"mouseDown:",@2:@"mouseUp:",@5:@"mouseMoved:",@6:@"mouseDragged:",@10:@"keyDown:",@11:@"keyUp:",@12:@"flagsChanged:"};
    SEL selector=NSSelectorFromString(selectors[@(event.type)]?:@"handleEvent:");if([view respondsToSelector:selector])((void(*)(id,SEL,id))objc_msgSend)(view,selector,event);
}
- (void)updateWindows { Main(^{for(NSWindow *w in self.windows)[w.nativeWindow layoutIfNeeded];}); }
@end

__attribute__((constructor)) static void SetupAppKit(void) {
    Runtime=[NSMutableDictionary new];Monitors=[NSMutableArray new];[NSApplication sharedApplication];
    [NSNotificationCenter.defaultCenter addObserverForName:UIApplicationDidBecomeActiveNotification object:nil queue:NSOperationQueue.mainQueue usingBlock:^(NSNotification *n){[NSNotificationCenter.defaultCenter postNotificationName:NSApplicationDidBecomeActiveNotification object:NSApp];}];
    [NSNotificationCenter.defaultCenter addObserverForName:UIApplicationWillResignActiveNotification object:nil queue:NSOperationQueue.mainQueue usingBlock:^(NSNotification *n){[NSNotificationCenter.defaultCenter postNotificationName:NSApplicationWillResignActiveNotification object:NSApp];}];
}
