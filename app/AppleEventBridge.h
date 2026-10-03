#import <Foundation/Foundation.h>

// Only the observed local quit-event registration is supported. This is not
// macOS Apple Event IPC, scripting, descriptor serialization, or suspension.
@interface NSAppleEventManager : NSObject
+ (instancetype)sharedAppleEventManager;
- (void)setEventHandler:(id)handler andSelector:(SEL)selector
         forEventClass:(uint32_t)eventClass andEventID:(uint32_t)eventID;
- (void)removeEventHandlerForEventClass:(uint32_t)eventClass andEventID:(uint32_t)eventID;
@end
