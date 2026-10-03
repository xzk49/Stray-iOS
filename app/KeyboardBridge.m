#import <Foundation/Foundation.h>
#include <stdint.h>
#include <string.h>

// ABI declarations follow the macOS SDK: UCKeyTranslate's UniCharCount is
// unsigned long on ARM64, not uint32_t. Layout bytes are Apple's real resource.
typedef struct { int32_t status; uint32_t length; uint16_t chars[8]; } StrayKeyResult;
#include "StrayUSKeyboard.inc"

const CFStringRef kTISPropertyUnicodeKeyLayoutData = CFSTR("TISPropertyUnicodeKeyLayoutData");

static CFDictionaryRef StrayUSInputSource(void) {
    static CFDictionaryRef source;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        CFDataRef layout = CFDataCreate(kCFAllocatorDefault, StrayUSLayoutBytes, sizeof(StrayUSLayoutBytes));
        const void *keys[] = {kTISPropertyUnicodeKeyLayoutData};
        const void *values[] = {layout};
        source = CFDictionaryCreate(kCFAllocatorDefault, keys, values, 1,
            &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
        CFRelease(layout);
    });
    return source;
}

// A CF object preserves the Copy/Get ownership convention expected by UE4.
CFTypeRef TISCopyCurrentKeyboardLayoutInputSource(void) {
    return CFRetain(StrayUSInputSource());
}

void *TISGetInputSourceProperty(CFTypeRef source, CFStringRef key) {
    if (!source || source != StrayUSInputSource() || !key) return NULL;
    return (void *)CFDictionaryGetValue((CFDictionaryRef)source, key);
}

uint8_t LMGetKbdType(void) { return 40; } // ANSI; matches the reference snapshot.

int32_t UCKeyTranslate(const void *layout, uint16_t key, uint16_t action,
    uint32_t modifiers, uint32_t keyboardType, uint32_t options,
    uint32_t *state, unsigned long capacity, unsigned long *length, uint16_t *characters) {
    if (!layout || !state || !length || !characters || key >= 128 || action >= 4 || modifiers >= 256)
        return -50; // paramErr
    CFDataRef data = CFDictionaryGetValue(StrayUSInputSource(), kTISPropertyUnicodeKeyLayoutData);
    if (layout != CFDataGetBytePtr(data)) return -50;
    // Reject modes we have not implemented, rather than pretending success.
    if (keyboardType != 40 || options != 1 || *state != 0) return -4; // unimpErr
    const StrayKeyResult *result = &StrayUSKeys[action][modifiers][key];
    *length = 0;
    if (result->status) return result->status;
    if (capacity < result->length) return -25340; // kUCOutputBufferTooSmall
    memcpy(characters, result->chars, result->length * sizeof(uint16_t));
    *length = result->length;
    return 0;
}

NSDictionary *StrayKeyboardCapabilities(void) {
    return @{@"layout": @"US-ANSI", @"native_reference_cases": @131072,
        @"no_dead_keys": @YES, @"system_layout_tracking": @NO, @"ime": @NO};
}
