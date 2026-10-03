#import "AppleEventBridge.h"
#import <UIKit/UIKit.h>
#import <objc/message.h>
#include <string.h>

static const uint32_t StrayCoreEventClass = 0x61657674; // aevt
static const uint32_t StrayQuitEventID = 0x71756974; // quit

// The game's quit handler ignores both arguments. Supply non-nil local event
// objects with type metadata; these are not serialized AppleEvent descriptors.
@interface StrayLifecycleEvent : NSObject
@property(nonatomic) uint32_t descriptorType;
@property(nonatomic) uint32_t eventClass;
@property(nonatomic) uint32_t eventID;
@end
@implementation StrayLifecycleEvent
@end

@interface NSAppleEventManager ()
@property(nonatomic, strong) id quitHandler;
@property(nonatomic) SEL quitSelector;
@property(nonatomic, strong) id terminationObserver;
- (BOOL)dispatchQuit;
@end

@implementation NSAppleEventManager
+ (instancetype)sharedAppleEventManager {
    static NSAppleEventManager *manager;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        manager = [NSAppleEventManager new];
        __weak NSAppleEventManager *weakManager = manager;
        manager.terminationObserver = [NSNotificationCenter.defaultCenter
            addObserverForName:UIApplicationWillTerminateNotification object:nil
            queue:NSOperationQueue.mainQueue usingBlock:^(NSNotification *notification) {
                (void)notification;
                [weakManager dispatchQuit];
            }];
    });
    return manager;
}
- (void)setEventHandler:(id)handler andSelector:(SEL)selector
         forEventClass:(uint32_t)eventClass andEventID:(uint32_t)eventID {
    if (eventClass != StrayCoreEventClass || eventID != StrayQuitEventID) {
        [NSException raise:NSInvalidArgumentException format:@"Only local quit events are supported by the iOS bridge"];
    }
    NSMethodSignature *signature = [handler methodSignatureForSelector:selector];
    if (!signature || signature.numberOfArguments != 4 || strcmp(signature.methodReturnType, @encode(void)) ||
        [signature getArgumentTypeAtIndex:2][0] != '@' || [signature getArgumentTypeAtIndex:3][0] != '@') {
        [NSException raise:NSInvalidArgumentException format:@"Quit handler must accept event and reply objects and return void"];
    }
    @synchronized(self) { self.quitHandler = handler; self.quitSelector = selector; }
}
- (void)removeEventHandlerForEventClass:(uint32_t)eventClass andEventID:(uint32_t)eventID {
    if (eventClass != StrayCoreEventClass || eventID != StrayQuitEventID) return;
    @synchronized(self) { self.quitHandler = nil; self.quitSelector = NULL; }
}
- (BOOL)dispatchQuit {
    NSAssert(NSThread.isMainThread, @"UIKit lifecycle events must be dispatched on the main thread");
    id handler; SEL selector;
    @synchronized(self) { handler = self.quitHandler; selector = self.quitSelector; }
    if (!handler || !selector) return NO;
    StrayLifecycleEvent *event = [StrayLifecycleEvent new];
    event.descriptorType = StrayCoreEventClass;
    event.eventClass = StrayCoreEventClass;
    event.eventID = StrayQuitEventID;
    StrayLifecycleEvent *reply = [StrayLifecycleEvent new];
    reply.descriptorType = 0x6e756c6c; // null; no reply requested.
    ((void (*)(id, SEL, id, id))objc_msgSend)(handler, selector, event, reply);
    return YES;
}
@end

BOOL StrayDispatchQuitEvent(void) {
    return [NSAppleEventManager.sharedAppleEventManager dispatchQuit];
}
