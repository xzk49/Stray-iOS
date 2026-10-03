#import <Foundation/Foundation.h>

// Cocoa is an umbrella framework on macOS. The audited game has no imports
// bound to it; the Foundation adapter is reexported without duplicate load
// commands in the guest. AppKit remains a separate compatibility requirement.
__attribute__((visibility("default")))
NSDictionary *StrayCocoaCapabilities(void) {
    return @{@"foundation": @"native-reexport-plus-local-quit-event",
             @"appkit": @"not-implemented",
             @"apple_event_ipc": @NO};
}
