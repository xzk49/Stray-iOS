#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#import <CommonCrypto/CommonDigest.h>
#import <objc/runtime.h>
#include <stdio.h>
#include <stdint.h>
#include <stdatomic.h>

@interface NSObject (StrayNativeMetalLibrary)
- (id<MTLLibrary>)stray_nativeNewLibraryWithData:(dispatch_data_t)data error:(NSError **)error __attribute__((objc_method_family(new)));
@end

@interface StrayMetalLibraryAdapter : NSObject
- (id<MTLLibrary>)stray_newLibraryWithData:(dispatch_data_t)data error:(NSError **)error __attribute__((objc_method_family(new)));
- (id<MTLLibrary>)stray_nativeOrRetargetLibraryWithData:(dispatch_data_t)data error:(NSError **)error __attribute__((objc_method_family(new)));
@end

static NSString *ShaderRoot;
static NSDictionary *ShaderManifest;
static NSDictionary *OriginalLibraries;
static atomic_uint RetargetedLibraries;
static atomic_bool CaptureGameLibraries;
static NSUInteger CapturedGameLibraryBytes;
static NSMutableDictionary *CapturedGameLibraries;

void StrayStopGameLibraryCapture(void){
    if(CapturedGameLibraries){@synchronized(CapturedGameLibraries){CaptureGameLibraries=NO;}}
    [NSFileManager.defaultManager removeItemAtPath:
        [NSHomeDirectory() stringByAppendingPathComponent:@"Documents/StrayCaptureMetalLibraries"] error:nil];
    fprintf(stderr,"STRAY_GAME_SHADER_CAPTURE stopped count=%lu bytes=%lu\n",
        (unsigned long)CapturedGameLibraries.count,(unsigned long)CapturedGameLibraryBytes);
}

static NSString *SHA256(const void *bytes,size_t length){
    unsigned char digest[CC_SHA256_DIGEST_LENGTH];char hex[CC_SHA256_DIGEST_LENGTH*2+1];
    CC_SHA256(bytes,(CC_LONG)length,digest);
    for(unsigned i=0;i<sizeof(digest);i++)snprintf(hex+i*2,3,"%02x",digest[i]);
    return @(hex);
}

static void CaptureGameLibrary(const void *bytes,size_t length,id<MTLLibrary> library){
    if(!CaptureGameLibraries || !library || length<88 || length>2*1024*1024)return;
    @synchronized(CapturedGameLibraries){
        if(!CaptureGameLibraries)return;
        NSString *hash=SHA256(bytes,length);
        if(CapturedGameLibraries[hash] || CapturedGameLibraries.count>=256 ||
           CapturedGameLibraryBytes+length>32*1024*1024)return;
        NSString *folder=[NSHomeDirectory() stringByAppendingPathComponent:@"Documents/StrayCapturedMetalLibraries"];
        NSError *error=nil;
        [NSFileManager.defaultManager createDirectoryAtPath:folder withIntermediateDirectories:YES attributes:nil error:&error];
        BOOL saved=[[NSData dataWithBytes:bytes length:length] writeToFile:
            [folder stringByAppendingPathComponent:[hash stringByAppendingPathExtension:@"metallib"]]
            options:NSDataWritingAtomic error:&error];
        if(saved){
            CapturedGameLibraryBytes+=length;
            CapturedGameLibraries[hash]=@{@"bytes":@(length),@"functions":library.functionNames};
            NSData *manifest=[NSJSONSerialization dataWithJSONObject:CapturedGameLibraries options:NSJSONWritingPrettyPrinted error:nil];
            [manifest writeToFile:[folder stringByAppendingPathComponent:@"manifest.json"] atomically:YES];
        }
        fprintf(stderr,"STRAY_GAME_SHADER_CAPTURE hash=%s bytes=%lu saved=%d count=%lu error=%s\n",
            hash.UTF8String,(unsigned long)length,saved,(unsigned long)CapturedGameLibraries.count,error.description.UTF8String?:"none");
    }
}

static void CaptureUnsupportedLibrary(dispatch_data_t data,NSError *failure){
    if(!failure || ![failure.domain isEqual:MTLLibraryErrorDomain])return;
    size_t size=dispatch_data_get_size(data);
    if(size<88 || size>512*1024*1024)return;
    const void *bytes=NULL;size_t length=0;
    dispatch_data_t mapped=dispatch_data_create_map(data,&bytes,&length);
    if(memcmp(bytes,"MTLB",4))return;
    NSString *hash=SHA256(bytes,length);
    NSString *folder=[NSHomeDirectory() stringByAppendingPathComponent:@"Documents/UnsupportedMetalLibraries"];
    NSError *error=nil;
    [NSFileManager.defaultManager createDirectoryAtPath:folder withIntermediateDirectories:YES attributes:nil error:&error];
    NSString *file=[folder stringByAppendingPathComponent:[hash stringByAppendingPathExtension:@"metallib"]];
    BOOL saved=[[NSData dataWithBytes:bytes length:length] writeToFile:file options:NSDataWritingAtomic error:&error];
    (void)mapped;
    fprintf(stderr,"STRAY_METAL_LIBRARY capture hash=%s bytes=%lu saved=%d error=%s\n",hash.UTF8String,
            (unsigned long)length,saved,error.description.UTF8String?:"none");
}

@implementation StrayMetalLibraryAdapter
- (id<MTLLibrary>)stray_nativeOrRetargetLibraryWithData:(dispatch_data_t)data error:(NSError **)error {
    NSError *failure=nil;id<MTLLibrary> library=[self stray_nativeNewLibraryWithData:data error:&failure];
    if(!library && [failure.domain isEqual:MTLLibraryErrorDomain] && failure.code==1){
        const void *bytes=NULL;size_t length=0;
        dispatch_data_t mapped=dispatch_data_create_map(data,&bytes,&length);
        const uint8_t *header=bytes;
        uint64_t declaredLength=0;
        if(length>=88)memcpy(&declaredLength,header+16,8);
        BOOL valid=length>=88 && !memcmp(header,"MTLB",4) && header[4]==1 && header[5]==0x80 &&
                   header[6]==2 && header[7]==0 && declaredLength==length;
        for(unsigned i=24;valid && i<88;i+=16){
            uint64_t offset=0,size=0;memcpy(&offset,header+i,8);memcpy(&size,header+i+8,8);
            valid=offset<=length && size<=length-offset;
        }
        if(valid){
            // Retarget the v2 library container's macOS flag. All function tables,
            // hashes, AIR bytecode, argument bindings and GPU feature requirements
            // remain byte-for-byte original. The native iOS loader/compiler must
            // accept it; failures remain real errors and are saved for rebuilding.
            void *owned=malloc(length);memcpy(owned,bytes,length);((uint8_t *)owned)[5]=0;
            dispatch_data_t ios=dispatch_data_create(owned,length,NULL,DISPATCH_DATA_DESTRUCTOR_FREE);
            NSError *retargetFailure=nil;
            library=[self stray_nativeNewLibraryWithData:ios error:&retargetFailure];
            if(library){
                CaptureGameLibrary(bytes,length,library);
                unsigned count=atomic_fetch_add(&RetargetedLibraries,1)+1;
                if(count<=16 || count%100==0)fprintf(stderr,"STRAY_METAL_LIBRARY ios_container_loaded count=%u bytes=%lu functions=%lu hash=%s\n",
                   count,(unsigned long)length,(unsigned long)library.functionNames.count,SHA256(bytes,length).UTF8String);
                failure=nil;
            }else fprintf(stderr,"STRAY_METAL_LIBRARY ios_container_rejected bytes=%lu error=%s\n",(unsigned long)length,retargetFailure.description.UTF8String);
        }
        (void)mapped;
    }
    if(error)*error=failure;if(!library)CaptureUnsupportedLibrary(data,failure);return library;
}
- (id<MTLLibrary>)stray_newLibraryWithData:(dispatch_data_t)data error:(NSError **)error {
    size_t size=dispatch_data_get_size(data);
    if(size!=3569 && size!=38944 && size!=16384){
        return [self stray_nativeOrRetargetLibraryWithData:data error:error];
    }
    const void *bytes=NULL;size_t mappedSize=0;
    dispatch_data_t mapped=dispatch_data_create_map(data,&bytes,&mappedSize);
    NSString *originalHash=SHA256(bytes,mappedSize);(void)mapped;
    NSString *filename=OriginalLibraries[originalHash];
    if(!filename){
        return [self stray_nativeOrRetargetLibraryWithData:data error:error];
    }
    NSDictionary *entry=ShaderManifest[originalHash];
    NSData *replacement=[NSData dataWithContentsOfFile:[ShaderRoot stringByAppendingPathComponent:filename]];
    if(!replacement || ![entry[@"filename"] isEqual:filename] ||
       ![SHA256(replacement.bytes,replacement.length) isEqual:entry[@"ios_sha256"]]){
        NSError *failure=[NSError errorWithDomain:@"StrayBinkShaderBridge" code:1
           userInfo:@{NSLocalizedDescriptionKey:@"Audited iOS Bink shader library is missing or does not match its manifest"}];
        if(error)*error=failure;
        fprintf(stderr,"STRAY_BINK_SHADER invalid_resource %s\n",filename.UTF8String);return nil;
    }
    void *owned=malloc(replacement.length);memcpy(owned,replacement.bytes,replacement.length);
    dispatch_data_t rebuilt=dispatch_data_create(owned,replacement.length,NULL,DISPATCH_DATA_DESTRUCTOR_FREE);
    NSError *failure=nil;
    id<MTLLibrary> library=[self stray_nativeNewLibraryWithData:rebuilt error:&failure];
    if(error)*error=failure;
    fprintf(stderr,"STRAY_BINK_SHADER load %s success=%d functions=%lu error=%s\n",filename.UTF8String,
            library!=nil,(unsigned long)library.functionNames.count,failure.description.UTF8String?:"none");
    return library;
}
@end

void StrayInstallBinkShaderBridge(id<MTLDevice> device){
    CaptureGameLibraries=[NSFileManager.defaultManager fileExistsAtPath:
        [NSHomeDirectory() stringByAppendingPathComponent:@"Documents/StrayCaptureMetalLibraries"]];
    if(CaptureGameLibraries)CapturedGameLibraries=[NSMutableDictionary new];
    if([NSFileManager.defaultManager fileExistsAtPath:
        [NSHomeDirectory() stringByAppendingPathComponent:@"Documents/StrayPerformanceDiagnostics"]])
        StrayStopGameLibraryCapture();
    ShaderRoot=[NSBundle.mainBundle.bundlePath stringByAppendingPathComponent:@"StrayShaderLibraries"];
    NSData *json=[NSData dataWithContentsOfFile:[ShaderRoot stringByAppendingPathComponent:@"manifest.json"]];
    if(!json)return;
    NSDictionary *manifest=[NSJSONSerialization JSONObjectWithData:json options:0 error:NULL];
    if([manifest[@"format"] integerValue]!=1 || ![manifest[@"target"] isEqual:@"air64_v21-apple-ios12.0.0"])return;
    OriginalLibraries=@{
      @"15c22098183171a5a935f2b72b234172a8b4cf2f57e544d7cc25380262bf4468":@"bink-vertex.metallib",
      @"2110c579afc3b84e47de1173cbd47fc5e14712d05a4b38fb5a04fdac4f1d1f7e":@"bink-ictcp.metallib",
      @"182c3b35035b32da9689be0a6f84763718ab4c4e16e6789f4721878820743123":@"bink-sdr.metallib"};
    NSMutableDictionary *entries=[NSMutableDictionary new];
    for(NSDictionary *entry in manifest[@"libraries"])entries[entry[@"source_sha256"]]=entry;
    ShaderManifest=[entries copy];
    Class cls=object_getClass(device);SEL native=@selector(newLibraryWithData:error:);
    Method method=class_getInstanceMethod(cls,native);
    if(!method || !class_addMethod(cls,@selector(stray_nativeNewLibraryWithData:error:),method_getImplementation(method),method_getTypeEncoding(method)))return;
    Method adapter=class_getInstanceMethod(StrayMetalLibraryAdapter.class,@selector(stray_newLibraryWithData:error:));
    Method loader=class_getInstanceMethod(StrayMetalLibraryAdapter.class,@selector(stray_nativeOrRetargetLibraryWithData:error:));
    class_addMethod(cls,@selector(stray_nativeOrRetargetLibraryWithData:error:),method_getImplementation(loader),method_getTypeEncoding(loader));
    class_replaceMethod(cls,native,method_getImplementation(adapter),method_getTypeEncoding(method));
    fprintf(stderr,"STRAY_BINK_SHADER install libraries=%lu\n",(unsigned long)ShaderManifest.count);
}
