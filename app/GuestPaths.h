#import <Foundation/Foundation.h>

// Resolve only inside the guest's resource/data roots. An ambiguous spelling
// fails instead of selecting a different file arbitrarily.
NSString *StrayResolveGuestPath(NSString *path, NSArray<NSString *> *roots);
