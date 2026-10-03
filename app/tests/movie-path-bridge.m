#import "../MoviePathBridge.h"
#include "../MovieProfile.h"
#include <assert.h>
#include <stdio.h>
int main(int argc,char **argv){@autoreleasepool{
    if(argc!=2)return 1;NSString *dir=[@(argv[1]) stringByStandardizingPath];
    for(NSString *stem in @[@"Bink_InsideTheWall_Falling_ZONE",@"Bink_EndCineOpeningCity",@"Bink_JailToMidtown"]){
        NSString *source=[dir stringByAppendingPathComponent:[stem stringByAppendingString:@".bk2"]];
        NSString *target=[dir stringByAppendingPathComponent:[stem stringByAppendingString:@"_1080p.bk2"]];
        assert([StrayPreferredMoviePath(source,dir) isEqual:target]);
        assert([StrayPreferredMoviePath(source.lowercaseString,dir) isEqual:target]);
        assert(StrayPreferredMoviePath(target,dir)==nil);
        NSFileHandle *a=[NSFileHandle fileHandleForReadingAtPath:source],*b=[NSFileHandle fileHandleForReadingAtPath:target];
        NSData *ah=[a readDataOfLength:44],*bh=[b readDataOfLength:44];[a closeFile];[b closeFile];
        uint64_t sa=[[NSFileManager.defaultManager attributesOfItemAtPath:source error:nil][NSFileSize] unsignedLongLongValue];
        uint64_t sb=[[NSFileManager.defaultManager attributesOfItemAtPath:target error:nil][NSFileSize] unsignedLongLongValue];
        assert(StrayMovieHeadersMatch(ah.bytes,ah.length,sa,bh.bytes,bh.length,sb));
        assert(!StrayMovieHeadersMatch(ah.bytes,43,sa,bh.bytes,bh.length,sb));
        assert(!StrayMovieHeadersMatch(ah.bytes,ah.length,sa,bh.bytes,bh.length,sb+1));
        uint8_t mismatch[44];memcpy(mismatch,bh.bytes,44);mismatch[8]^=1;
        assert(!StrayMovieHeadersMatch(ah.bytes,ah.length,sa,mismatch,44,sb));
        memcpy(mismatch,bh.bytes,44);mismatch[28]^=1;
        assert(!StrayMovieHeadersMatch(ah.bytes,ah.length,sa,mismatch,44,sb));
        memcpy(mismatch,bh.bytes,44);mismatch[40]^=1;
        assert(!StrayMovieHeadersMatch(ah.bytes,ah.length,sa,mismatch,44,sb));
        assert(StrayPreferredMoviePath(source,[dir stringByAppendingString:@"-other"])==nil);
    }
    assert(StrayPreferredMoviePath([dir stringByAppendingPathComponent:@"Other.bk2"],dir)==nil);
    NSString *missing=[NSTemporaryDirectory() stringByAppendingPathComponent:NSUUID.UUID.UUIDString];
    assert(StrayPreferredMoviePath([missing stringByAppendingPathComponent:@"Bink_JailToMidtown.bk2"],missing)==nil);
    puts("movie routing: all three real pairs, timing checks, truncated/invalid headers and directory scope passed");
}}
