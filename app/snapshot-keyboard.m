#import <Carbon/Carbon.h>
#include <stdio.h>

// Generate reference results with Apple's implementation. The bridge supports
// the game's observed no-dead-keys calls, using a fixed US/ANSI layout.
int main(int argc, char **argv) {
    if (argc != 3) return 2;
    @autoreleasepool {
        NSDictionary *filter = @{(__bridge NSString *)kTISPropertyInputSourceID: @"com.apple.keylayout.US"};
        CFArrayRef sources = TISCreateInputSourceList((__bridge CFDictionaryRef)filter, true);
        if (!sources || CFArrayGetCount(sources) != 1) return 3;
        TISInputSourceRef source = (TISInputSourceRef)CFArrayGetValueAtIndex(sources, 0);
        CFDataRef data = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData);
        if (!data || CFGetTypeID(data) != CFDataGetTypeID()) return 4;
        const UCKeyboardLayout *layout = (const UCKeyboardLayout *)CFDataGetBytePtr(data);
        FILE *file = fopen(argv[1], "w");
        if (!file) return 5;
        fprintf(file, "// Generated from Apple's US keyboard layout; do not hand edit.\n");
        fprintf(file, "static const unsigned char StrayUSLayoutBytes[] = {\n");
        for (CFIndex i = 0; i < CFDataGetLength(data); i++) {
            fprintf(file, "%u,%s", CFDataGetBytePtr(data)[i], i % 32 == 31 ? "\n" : "");
        }
        fprintf(file, "\n};\nstatic const StrayKeyResult StrayUSKeys[4][256][128] = {\n");
        for (unsigned action = 0; action < 4; action++) {
            fprintf(file, "{\n");
            for (unsigned modifier = 0; modifier < 256; modifier++) {
                fprintf(file, "{\n");
                for (unsigned key = 0; key < 128; key++) {
                    UInt32 state = 0;
                    UniChar chars[8] = {0};
                    UniCharCount length = 0;
                    OSStatus status = UCKeyTranslate(layout, key, action, modifier, 40,
                        kUCKeyTranslateNoDeadKeysMask, &state, 8, &length, chars);
                    if (state != 0 || length > 8) { fclose(file); return 6; }
                    fprintf(file, "{%d,%lu,{", (int)status, length);
                    for (int i = 0; i < 8; i++) fprintf(file, "%u%s", chars[i], i == 7 ? "" : ",");
                    fprintf(file, "}},\n");
                }
                fprintf(file, "},\n");
            }
            fprintf(file, "},\n");
        }
        fprintf(file, "};\n");
        if (fclose(file)) return 7;
        NSMutableArray *cases = [NSMutableArray new];
        unsigned keys[] = {0, 14, 18, 24, 27, 36, 48, 49, 51, 65, 123, 127};
        unsigned modifiers[] = {0, 1, 2, 4, 6, 8, 10, 16, 32, 64, 128, 255};
        for (unsigned action = 0; action < 4; action++) {
            for (unsigned k = 0; k < sizeof(keys)/sizeof(keys[0]); k++) {
                for (unsigned m = 0; m < sizeof(modifiers)/sizeof(modifiers[0]); m++) {
                    UInt32 state = 0;
                    UniChar chars[8] = {0};
                    UniCharCount length = 0;
                    OSStatus status = UCKeyTranslate(layout, keys[k], action, modifiers[m], 40,
                        kUCKeyTranslateNoDeadKeysMask, &state, 8, &length, chars);
                    NSMutableArray *output = [NSMutableArray new];
                    for (unsigned long i = 0; i < length; i++) [output addObject:@(chars[i])];
                    [cases addObject:@{@"key": @(keys[k]), @"action": @(action),
                        @"modifiers": @(modifiers[m]), @"status": @(status), @"characters": output}];
                }
            }
        }
        NSData *json = [NSJSONSerialization dataWithJSONObject:cases options:0 error:nil];
        if (![json writeToFile:@(argv[2]) atomically:YES]) return 8;
        CFRelease(sources);
    }
    return 0;
}
