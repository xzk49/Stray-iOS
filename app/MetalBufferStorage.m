#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#import <objc/runtime.h>
#include <stdatomic.h>
#include <stdio.h>

// macOS Managed buffers have separate CPU/GPU copies. On this unified-memory
// device Shared supplies the same CPU access without an unsupported storage mode.
// Preserve bytes, length, other option bits and the original deallocator.
static atomic_uint BufferTranslations;
static MTLResourceOptions NativeBufferOptions(MTLResourceOptions options,NSUInteger length,const char *kind){
    if(((options&MTLResourceStorageModeMask)>>MTLResourceStorageModeShift)!=1)return options;
    unsigned count=atomic_fetch_add(&BufferTranslations,1)+1;
    if(count<=32)fprintf(stderr,"STRAY_METAL_ABI managed_buffer_to_shared kind=%s length=%lu count=%u\n",kind,(unsigned long)length,count);
    return (options&~MTLResourceStorageModeMask)|MTLResourceStorageModeShared;
}
@interface NSObject (StrayNativeBuffers)
- (id<MTLBuffer>)stray_nativeBufferWithLength:(NSUInteger)n options:(MTLResourceOptions)o __attribute__((objc_method_family(new)));
- (id<MTLBuffer>)stray_nativeBufferWithBytes:(const void *)p length:(NSUInteger)n options:(MTLResourceOptions)o __attribute__((objc_method_family(new)));
- (id<MTLBuffer>)stray_nativeBufferWithBytesNoCopy:(void *)p length:(NSUInteger)n options:(MTLResourceOptions)o deallocator:(void (^)(void *,NSUInteger))d __attribute__((objc_method_family(new)));
@end
@interface StrayBufferStorageAdapter : NSObject @end
@implementation StrayBufferStorageAdapter
- (id<MTLBuffer>)stray_bufferWithLength:(NSUInteger)n options:(MTLResourceOptions)o __attribute__((objc_method_family(new))){
    return [self stray_nativeBufferWithLength:n options:NativeBufferOptions(o,n,"length")];
}
- (id<MTLBuffer>)stray_bufferWithBytes:(const void *)p length:(NSUInteger)n options:(MTLResourceOptions)o __attribute__((objc_method_family(new))){
    return [self stray_nativeBufferWithBytes:p length:n options:NativeBufferOptions(o,n,"bytes")];
}
- (id<MTLBuffer>)stray_bufferWithBytesNoCopy:(void *)p length:(NSUInteger)n options:(MTLResourceOptions)o deallocator:(void (^)(void *,NSUInteger))d __attribute__((objc_method_family(new))){
    return [self stray_nativeBufferWithBytesNoCopy:p length:n options:NativeBufferOptions(o,n,"no_copy") deallocator:d];
}
@end
void StrayInstallMetalBufferStorage(id<MTLDevice> device){
    if(!device.hasUnifiedMemory)return;
    NSArray *selectors=@[
        @[@"newBufferWithLength:options:",@"stray_nativeBufferWithLength:options:",@"stray_bufferWithLength:options:"],
        @[@"newBufferWithBytes:length:options:",@"stray_nativeBufferWithBytes:length:options:",@"stray_bufferWithBytes:length:options:"],
        @[@"newBufferWithBytesNoCopy:length:options:deallocator:",@"stray_nativeBufferWithBytesNoCopy:length:options:deallocator:",@"stray_bufferWithBytesNoCopy:length:options:deallocator:"]];
    Class cls=object_getClass(device);unsigned installed=0;
    for(NSArray *entry in selectors){
        SEL native=NSSelectorFromString(entry[0]),saved=NSSelectorFromString(entry[1]);
        Method method=class_getInstanceMethod(cls,native),adapter=class_getInstanceMethod(StrayBufferStorageAdapter.class,NSSelectorFromString(entry[2]));
        if(!method || !adapter || !class_addMethod(cls,saved,method_getImplementation(method),method_getTypeEncoding(method)))continue;
        class_replaceMethod(cls,native,method_getImplementation(adapter),method_getTypeEncoding(method));installed++;
    }
    fprintf(stderr,"STRAY_METAL_ABI install_unified_buffer_storage installed=%u class=%s\n",installed,class_getName(cls));
}
