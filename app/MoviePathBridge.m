#import "MoviePathBridge.h"
#import "GuestPaths.h"
#include "MovieProfile.h"
#include <stdio.h>

static NSData *Header(NSString *path){
    NSFileHandle *file=[NSFileHandle fileHandleForReadingAtPath:path];if(!file)return nil;
    NSError *error=nil;NSData *bytes=[file readDataUpToLength:44 error:&error];[file closeFile];return error?nil:bytes;
}
NSString *StrayPreferredMoviePath(NSString *path,NSString *movieDirectory){
    if(!path.length || !movieDirectory.length)return nil;
    NSString *absolute=path.isAbsolutePath?path:[NSFileManager.defaultManager.currentDirectoryPath stringByAppendingPathComponent:path];
    absolute=absolute.stringByStandardizingPath;movieDirectory=movieDirectory.stringByStandardizingPath;
    if([absolute.stringByDeletingLastPathComponent caseInsensitiveCompare:movieDirectory]!=NSOrderedSame)return nil;
    NSArray *names=@[@"Bink_InsideTheWall_Falling_ZONE.bk2",@"Bink_EndCineOpeningCity.bk2",@"Bink_JailToMidtown.bk2"];
    NSString *matched=nil;for(NSString *name in names)if([name caseInsensitiveCompare:absolute.lastPathComponent]==NSOrderedSame){matched=name;break;}
    if(!matched)return nil;
    static NSMutableDictionary *validated;static dispatch_once_t once;dispatch_once(&once,^{validated=[NSMutableDictionary new];});
    @synchronized(validated){
        id cached=validated[absolute];if(cached)return cached==NSNull.null?nil:cached;
        NSString *source=StrayResolveGuestPath(absolute,@[movieDirectory]);
        NSString *target=[movieDirectory stringByAppendingPathComponent:[[matched stringByDeletingPathExtension] stringByAppendingString:@"_1080p.bk2"]];
        NSData *a=source?Header(source):nil,*b=Header(target);
        NSDictionary *sa=source?[NSFileManager.defaultManager attributesOfItemAtPath:source error:nil]:nil,*sb=[NSFileManager.defaultManager attributesOfItemAtPath:target error:nil];
        BOOL valid=a && b && StrayMovieHeadersMatch(a.bytes,a.length,[sa[NSFileSize] unsignedLongLongValue],b.bytes,b.length,[sb[NSFileSize] unsignedLongLongValue]);
        validated[absolute]=valid?target:(id)NSNull.null;
        fprintf(stderr,"STRAY_MOVIE_PROFILE original=%s selected=%s matched_headers=%d\n",matched.UTF8String,valid?target.lastPathComponent.UTF8String:"original",valid);
        return valid?target:nil;
    }
}
