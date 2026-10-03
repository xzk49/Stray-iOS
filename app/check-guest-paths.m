#import "GuestPaths.h"
#include <assert.h>

int main(int argc,const char **argv){@autoreleasepool {
    assert(argc==2);
    NSString *root=[NSString stringWithUTF8String:argv[1]];
    NSFileManager *fm=NSFileManager.defaultManager;
    assert([fm createDirectoryAtPath:[root stringByAppendingPathComponent:@"Content/Movies"] withIntermediateDirectories:YES attributes:nil error:nil]);
    NSString *file=[root stringByAppendingPathComponent:@"Content/Movies/Intro.BK2"];
    assert([@"probe" writeToFile:file atomically:YES encoding:NSUTF8StringEncoding error:nil]);
    NSArray *roots=@[root];
    assert([StrayResolveGuestPath([root stringByAppendingPathComponent:@"content/mOVIES/intro.bk2"],roots) isEqualToString:file]);
    assert([StrayResolveGuestPath([root stringByAppendingPathComponent:@"Content/Movies/New.Save"],roots) isEqualToString:[root stringByAppendingPathComponent:@"Content/Movies/New.Save"]]);
    assert(!StrayResolveGuestPath([root stringByAppendingPathComponent:@"missing/parent/file"],roots));
    assert(!StrayResolveGuestPath([root stringByAppendingString:@"-sibling/Content/file"],roots));
    assert(!StrayResolveGuestPath([root stringByAppendingPathComponent:@"../outside"],roots));
    assert([fm changeCurrentDirectoryPath:root]);
    assert([StrayResolveGuestPath(@"content/mOVIES/intro.bk2",roots) isEqualToString:file]);
    assert([@"probe" isEqualToString:[NSString stringWithContentsOfFile:StrayResolveGuestPath(@"content/movies/intro.bk2",roots) encoding:NSUTF8StringEncoding error:nil]]);
    puts("Guest paths: casing, relative lookup, new leaf, missing parents and root boundaries passed");
}}
