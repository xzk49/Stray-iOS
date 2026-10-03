#import <Foundation/Foundation.h>
static inline NSString *StrayRootFromHostBundle(id bundle) {
    NSString *relative=[bundle objectForInfoDictionaryKey:@"StrayGameRelativeRoot"];
    if(relative.length)return [[bundle bundlePath] stringByAppendingPathComponent:relative];
    return [bundle objectForInfoDictionaryKey:@"StrayGameRoot"];
}
