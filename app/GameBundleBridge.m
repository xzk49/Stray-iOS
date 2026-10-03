#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import "GameRoot.h"
static Class NativeBundle(void) { return objc_getClass("NSBundle"); }

// Exported under NSBundle only to the guest's Foundation dependency. The host
// continues binding to Apple's NSBundle. Preserve the cooked macOS bundle layout.
@interface StrayGameBundle : NSObject
@property(nonatomic,copy) NSString *bundlePath;
@property(nonatomic,strong) NSDictionary *infoDictionary;
+ (id)mainBundle;
+ (id)bundleWithPath:(NSString *)path;
+ (id)bundleForClass:(Class)cls;
@end
@implementation StrayGameBundle
+ (id)mainBundle {
    static id bundle; static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSString *root=StrayRootFromHostBundle([NativeBundle() mainBundle]);
        bundle=root?[self bundleWithPath:root]:[NativeBundle() mainBundle];
    });
    return bundle;
}
+ (id)bundleWithPath:(NSString *)path {
    NSString *plist=[path stringByAppendingPathComponent:@"Contents/Info.plist"];
    if(![NSFileManager.defaultManager fileExistsAtPath:plist])return [NativeBundle() bundleWithPath:path];
    StrayGameBundle *bundle=[self new];bundle.bundlePath=path;
    bundle.infoDictionary=[NSDictionary dictionaryWithContentsOfFile:plist];return bundle;
}
+ (id)bundleForClass:(Class)cls { return [NativeBundle() bundleForClass:cls]; }
- (NSString *)executablePath { return [[self.bundlePath stringByAppendingPathComponent:@"Contents/MacOS"] stringByAppendingPathComponent:self.infoDictionary[@"CFBundleExecutable"]]; }
- (NSString *)resourcePath { return [self.bundlePath stringByAppendingPathComponent:@"Contents/Resources"]; }
- (NSURL *)bundleURL { return [NSURL fileURLWithPath:self.bundlePath isDirectory:YES]; }
- (NSURL *)executableURL { return [NSURL fileURLWithPath:[self executablePath]]; }
- (NSURL *)resourceURL { return [NSURL fileURLWithPath:[self resourcePath] isDirectory:YES]; }
- (NSString *)bundleIdentifier { return self.infoDictionary[@"CFBundleIdentifier"]; }
- (id)objectForInfoDictionaryKey:(NSString *)key { return self.infoDictionary[key]; }
- (NSDictionary *)localizedInfoDictionary { return self.infoDictionary; }
- (NSArray *)localizations { return self.infoDictionary[@"CFBundleLocalizations"]?:@[]; }
- (NSArray *)preferredLocalizations { return [NativeBundle() preferredLocalizationsFromArray:[self localizations]]; }
- (NSString *)pathForResource:(NSString *)name ofType:(NSString *)type { return [self pathForResource:name ofType:type inDirectory:nil]; }
- (NSString *)pathForResource:(NSString *)name ofType:(NSString *)type inDirectory:(NSString *)directory {
    NSString *file=type.length?[name stringByAppendingPathExtension:type]:name;
    NSString *base=directory?[[self resourcePath] stringByAppendingPathComponent:directory]:[self resourcePath];
    NSString *path=[base stringByAppendingPathComponent:file];
    return [NSFileManager.defaultManager fileExistsAtPath:path]?path:nil;
}
- (NSURL *)URLForResource:(NSString *)name withExtension:(NSString *)type {
    NSString *path=[self pathForResource:name ofType:type];return path?[NSURL fileURLWithPath:path]:nil;
}
- (id)forwardingTargetForSelector:(SEL)selector { return [NativeBundle() bundleWithPath:self.bundlePath]; }
@end
