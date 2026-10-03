#import <Foundation/Foundation.h>
#include <string.h>
#include <dlfcn.h>
#include <stdio.h>
#include <errno.h>
#include <fcntl.h>
#include <stdarg.h>
#include <sys/stat.h>
#include <dirent.h>
#include <unistd.h>
#import "GameRoot.h"
#import "GuestPaths.h"
#import "MoviePathBridge.h"

static NSArray<NSString *> *GuestRoots(void){
    static NSArray *roots;static dispatch_once_t once;
    dispatch_once(&once,^{NSString *game=StrayRootFromHostBundle(NSBundle.mainBundle);roots=game?@[game,NSHomeDirectory()]:@[NSHomeDirectory()];});
    return roots;
}
static NSString *GuestMoviePath(const char *path){
    if(!path)return nil;
    const char *leaf=strrchr(path,'/');leaf=leaf?leaf+1:path;
    if(strncasecmp(leaf,"Bink_",5))return nil;
    static NSString *directory;static BOOL enabled;static dispatch_once_t once;
    dispatch_once(&once,^{
        NSDictionary *profile=[NSDictionary dictionaryWithContentsOfFile:[NSHomeDirectory() stringByAppendingPathComponent:@"Documents/StrayRenderProfile.plist"]];
        enabled=!profile[@"prefer1080pMovies"] || [profile[@"prefer1080pMovies"] boolValue];
        NSString *root=StrayRootFromHostBundle(NSBundle.mainBundle);directory=root?[root stringByAppendingPathComponent:@"Contents/UE4/Hk_project/Content/Movies"]:nil;
    });
    if(!enabled)return nil;
    return StrayPreferredMoviePath([[NSString alloc]initWithUTF8String:path],directory);
}
static NSString *GuestRetryPath(const char *path,int originalError){
    if(!path || (originalError!=ENOENT && originalError!=ENOTDIR))return nil;
    NSString *name=[[NSString alloc]initWithUTF8String:path];
    NSString *resolved=StrayResolveGuestPath(name,GuestRoots());
    if(resolved && ![resolved isEqualToString:name])fprintf(stderr,"STRAY_RUNTIME case_path %s -> %s\n",path,resolved.fileSystemRepresentation);
    return resolved;
}
#define NATIVE(name, type) static type native;static dispatch_once_t once;dispatch_once(&once,^{native=dlsym(RTLD_NEXT,name);});if(!native){errno=ENOSYS;return -1;}
int StrayGuestOpen(const char *path,int flags,...){
    mode_t mode=0;if(flags&O_CREAT){va_list args;va_start(args,flags);mode=(mode_t)va_arg(args,int);va_end(args);}
    typedef int (*Fn)(const char *,int,...);NATIVE("open",Fn)
    if(!(flags&(O_CREAT|O_TRUNC|O_WRONLY|O_RDWR))){@autoreleasepool {NSString *movie=GuestMoviePath(path);if(movie)return native(movie.fileSystemRepresentation,flags,mode);}}
    if(path && (flags&O_CREAT)){
        @autoreleasepool {NSString *canonical=StrayResolveGuestPath([[NSString alloc]initWithUTF8String:path],GuestRoots());if(canonical)return native(canonical.fileSystemRepresentation,flags,mode);}
    }
    int result=native(path,flags,mode),saved=errno;if(result>=0)return result;
    @autoreleasepool {NSString *retry=GuestRetryPath(path,saved);if(retry)return native(retry.fileSystemRepresentation,flags,mode);}
    errno=saved;return result;
}
FILE *StrayGuestFopen(const char *path,const char *mode){
    static FILE *(*native)(const char *,const char *);static dispatch_once_t once;dispatch_once(&once,^{native=dlsym(RTLD_NEXT,"fopen");});
    if(!native){errno=ENOSYS;return NULL;}
    if(mode && mode[0]=='r' && !strchr(mode,'+')){@autoreleasepool {NSString *movie=GuestMoviePath(path);if(movie)return native(movie.fileSystemRepresentation,mode);}}
    if(path && mode && (mode[0]=='w' || mode[0]=='a')){
        @autoreleasepool {NSString *canonical=StrayResolveGuestPath([[NSString alloc]initWithUTF8String:path],GuestRoots());if(canonical)return native(canonical.fileSystemRepresentation,mode);}
    }
    FILE *result=native(path,mode);int saved=errno;if(result)return result;
    @autoreleasepool {NSString *retry=GuestRetryPath(path,saved);if(retry)return native(retry.fileSystemRepresentation,mode);}
    errno=saved;return result;
}
int StrayGuestStat(const char *path,struct stat *value){
    typedef int (*Fn)(const char *,struct stat *);NATIVE("stat",Fn)
    @autoreleasepool {NSString *movie=GuestMoviePath(path);if(movie)return native(movie.fileSystemRepresentation,value);}
    int result=native(path,value),saved=errno;if(!result)return result;
    @autoreleasepool {NSString *retry=GuestRetryPath(path,saved);if(retry)return native(retry.fileSystemRepresentation,value);}
    errno=saved;return result;
}
int StrayGuestAccess(const char *path,int mode){
    typedef int (*Fn)(const char *,int);NATIVE("access",Fn)
    if(!(mode&W_OK)){@autoreleasepool {NSString *movie=GuestMoviePath(path);if(movie)return native(movie.fileSystemRepresentation,mode);}}
    int result=native(path,mode),saved=errno;if(!result)return result;
    @autoreleasepool {NSString *retry=GuestRetryPath(path,saved);if(retry)return native(retry.fileSystemRepresentation,mode);}
    errno=saved;return result;
}
DIR *StrayGuestOpendir(const char *path){
    static DIR *(*native)(const char *);static dispatch_once_t once;dispatch_once(&once,^{native=dlsym(RTLD_NEXT,"opendir");});
    if(!native){errno=ENOSYS;return NULL;}DIR *result=native(path);int saved=errno;if(result)return result;
    @autoreleasepool {NSString *retry=GuestRetryPath(path,saved);if(retry)return native(retry.fileSystemRepresentation);}
    errno=saved;return result;
}
int StrayGuestChdir(const char *path){
    typedef int (*Fn)(const char *);NATIVE("chdir",Fn)
    int result=native(path),saved=errno;if(!result)return result;
    @autoreleasepool {NSString *retry=GuestRetryPath(path,saved);if(retry)return native(retry.fileSystemRepresentation);}
    errno=saved;return result;
}
int StrayGuestMkdir(const char *path,mode_t mode){
    typedef int (*Fn)(const char *,mode_t);NATIVE("mkdir",Fn)
    @autoreleasepool {NSString *canonical=path?StrayResolveGuestPath([[NSString alloc]initWithUTF8String:path],GuestRoots()):nil;return native(canonical?canonical.fileSystemRepresentation:path,mode);}
}
int StrayGuestUnlink(const char *path){
    typedef int (*Fn)(const char *);NATIVE("unlink",Fn)
    int result=native(path),saved=errno;if(!result)return result;
    @autoreleasepool {NSString *retry=GuestRetryPath(path,saved);if(retry)return native(retry.fileSystemRepresentation);}
    errno=saved;return result;
}
int StrayGuestRename(const char *from,const char *to){
    typedef int (*Fn)(const char *,const char *);NATIVE("rename",Fn)
    @autoreleasepool {
        NSString *source=from?StrayResolveGuestPath([[NSString alloc]initWithUTF8String:from],GuestRoots()):nil;
        NSString *destination=to?StrayResolveGuestPath([[NSString alloc]initWithUTF8String:to],GuestRoots()):nil;
        return native(source?source.fileSystemRepresentation:from,destination?destination.fileSystemRepresentation:to);
    }
}
#undef NATIVE

void *StrayGuestDlopen(const char *filename,int mode) {
    static void *(*native)(const char *,int);static dispatch_once_t once;
    dispatch_once(&once,^{native=dlsym(RTLD_NEXT,"dlopen");});
    if(!native || native==StrayGuestDlopen)return NULL;
    if(filename){
        NSString *path=@(filename),*name=path.lastPathComponent;
        if([path.pathExtension isEqualToString:@"dylib"])fprintf(stderr,"STRAY_RUNTIME requested_library %s\n",filename);
        NSSet *audited=[NSSet setWithArray:@[@"libPxFoundation.dylib",@"libPxPvdSDK.dylib",@"libPhysX3Common.dylib",@"libPhysX3.dylib",@"libPhysX3Cooking.dylib",@"libApexFramework.dylib",@"libAPEX_Legacy.dylib",@"libAPEX_Clothing.dylib",@"libAPEX_Destructible.dylib",@"libNvCloth.dylib",@"libogg.dylib",@"libvorbis.dylib"]];
        NSString *canonical=nil;for(NSString *candidate in audited)if([candidate caseInsensitiveCompare:name]==NSOrderedSame){canonical=candidate;break;}
        if([path containsString:@"Binaries/ThirdParty/"] && canonical){
            NSString *mapped=[[NSBundle.mainBundle.bundlePath stringByAppendingPathComponent:@"Frameworks"] stringByAppendingPathComponent:canonical];
            fprintf(stderr,"STRAY_RUNTIME dlopen %s -> %s mode=%x\n",filename,mapped.fileSystemRepresentation,mode);
            return native(mapped.fileSystemRepresentation,mode);
        }
    }
    return native(filename,mode);
}
int _NSGetExecutablePath(char *buffer,uint32_t *size){
    NSString *root=StrayRootFromHostBundle(NSBundle.mainBundle);
    if(!root || !size)return -1;
    NSString *path=[root stringByAppendingPathComponent:@"Contents/MacOS/Stray-Mac-Shipping"];
    const char *utf8=path.fileSystemRepresentation;uint32_t required=(uint32_t)strlen(utf8)+1;
    if(!buffer || *size<required){*size=required;return -1;}memcpy(buffer,utf8,required);return 0;
}
