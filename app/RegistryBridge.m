#import <Foundation/Foundation.h>
CFDictionaryRef IODisplayCreateInfoDictionary(uint32_t service,uint32_t options){
    NSLog(@"STRAY_IOKIT Mac display registry unavailable on iOS (service %u)",service);return NULL;
}
CFDictionaryRef KextManagerCopyLoadedKextInfo(CFArrayRef identifiers,CFArrayRef keys){
    // iOS does not expose the macOS kernel-extension registry to applications.
    NSLog(@"STRAY_IOKIT macOS kext information unavailable on iOS");return NULL;
}
CFURLRef KextManagerCreateURLForBundleIdentifier(CFAllocatorRef allocator,CFStringRef identifier){return NULL;}
