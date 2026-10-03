#import "GuestPaths.h"

NSString *StrayResolveGuestPath(NSString *path, NSArray<NSString *> *roots) {
    if(!path.length)return nil;
    if(!path.isAbsolutePath)path=[NSFileManager.defaultManager.currentDirectoryPath stringByAppendingPathComponent:path];
    path=path.stringByStandardizingPath;
    NSArray<NSString *> *components=path.pathComponents;
    for(NSString *root in roots){
        NSArray<NSString *> *prefix=root.stringByStandardizingPath.pathComponents;
        if(components.count<prefix.count)continue;
        BOOL inside=YES;
        for(NSUInteger i=0;i<prefix.count;i++)if([prefix[i] caseInsensitiveCompare:components[i]]!=NSOrderedSame){inside=NO;break;}
        if(!inside)continue;
        NSString *resolved=root.stringByStandardizingPath;
        for(NSUInteger i=prefix.count;i<components.count;i++){
            NSString *component=components[i],*exact=[resolved stringByAppendingPathComponent:component];
            NSArray<NSString *> *names=[NSFileManager.defaultManager contentsOfDirectoryAtPath:resolved error:nil];
            if(!names)return nil;
            if([names containsObject:component]){resolved=exact;continue;}
            NSString *match=nil;
            for(NSString *name in names)if([name caseInsensitiveCompare:component]==NSOrderedSame){if(match)return nil;match=name;}
            if(!match){
                // A new leaf may be created, but missing parent directories
                // must keep the native ENOENT result.
                return i+1==components.count?exact:nil;
            }
            resolved=[resolved stringByAppendingPathComponent:match];
        }
        return resolved;
    }
    return nil;
}
