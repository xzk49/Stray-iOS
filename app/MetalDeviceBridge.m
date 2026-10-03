#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#import <objc/runtime.h>
#include <stdio.h>
#include <stdatomic.h>
#include <mach-o/dyld.h>
#include <mach-o/loader.h>
#include <string.h>

static BOOL (*NativeSupportsFeatureSet)(id,SEL,MTLFeatureSet);
static BOOL TextureBufferProbePassed;
static void (*NativeTextureSetLabel)(id,SEL,NSString *);
static atomic_uint TextureResidencyMessages;

static void StrayTextureSetLabel(id<MTLTexture> texture,SEL selector,NSString *label){
    NativeTextureSetLabel(texture,selector,label);
    NSString *name=label.lowercaseString;
    if(![name containsString:@"concrete"] && ![name containsString:@"pipe"] &&
       ![name containsString:@"water"] && ![name hasPrefix:@"cat_"])return;
    if(atomic_fetch_add(&TextureResidencyMessages,1)>=256)return;
    fprintf(stderr,"STRAY_TEXTURE_RESIDENCY label=%s size=%lux%lu mips=%lu format=%lu storage=%lu\n",
        label.UTF8String,(unsigned long)texture.width,(unsigned long)texture.height,
        (unsigned long)texture.mipmapLevelCount,(unsigned long)texture.pixelFormat,(unsigned long)texture.storageMode);
}

static void StrayInstallTextureResidencyObserver(id<MTLDevice> device){
    NSDictionary *profile=[NSDictionary dictionaryWithContentsOfFile:[NSHomeDirectory() stringByAppendingPathComponent:@"Documents/StrayRenderProfile.plist"]];
    if(![profile[@"textureDiagnostics"] boolValue])return;
    MTLTextureDescriptor *descriptor=[MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA8Unorm width:4 height:4 mipmapped:NO];
    descriptor.storageMode=MTLStorageModePrivate;
    id<MTLTexture> texture=[device newTextureWithDescriptor:descriptor];
    Class cls=object_getClass(texture);SEL selector=@selector(setLabel:);
    Method method=class_getInstanceMethod(cls,selector);
    if(!method)return;
    NativeTextureSetLabel=(void(*)(id,SEL,NSString *))method_getImplementation(method);
    class_replaceMethod(cls,selector,(IMP)StrayTextureSetLabel,method_getTypeEncoding(method));
    fprintf(stderr,"STRAY_TEXTURE_RESIDENCY observer_class=%s limit=256\n",class_getName(cls));
}

// Stray 1.6's Mac RHI gates texture_buffer views behind a Mac feature set.
// iOS correctly returns NO for that feature set, but its native buffer textures
// are supported. Match the audited image and constructor state before supplying
// only that capability. Neither executable instructions nor query results change.
static void StrayEnableGuestTextureBuffers(void){
    static const unsigned char uuid[16]={0xb2,0x3c,0xfb,0xe6,0x80,0xd4,0x32,0xaa,0x96,0x75,0x5f,0x9a,0x5e,0xd4,0x53,0xde};
    for(uint32_t i=0;i<_dyld_image_count();i++){
        const char *name=_dyld_get_image_name(i);
        if(!name || !strstr(name,"/StrayGuest.dylib"))continue;
        const struct mach_header_64 *header=(const void *)_dyld_get_image_header(i);
        if(header->magic!=MH_MAGIC_64)continue;
        const struct load_command *command=(const void *)(header+1);
        BOOL matched=NO,writable=NO;
        for(uint32_t j=0;j<header->ncmds;j++){
            if(command->cmd==LC_UUID)matched=!memcmp(((const struct uuid_command *)command)->uuid,uuid,16);
            if(command->cmd==LC_SEGMENT_64){
                const struct segment_command_64 *segment=(const void *)command;
                if(segment->vmaddr<=0x1053431a0ULL && segment->vmaddr+segment->vmsize>=0x1053431a8ULL)
                    writable=(segment->initprot&VM_PROT_WRITE)!=0;
            }
            command=(const void *)((const char *)command+command->cmdsize);
        }
        if(!matched || !writable)return;
        intptr_t slide=_dyld_get_image_vmaddr_slide(i);
        if(*(const uint32_t *)(slide+0x1011cc8dcULL)!=0x5284e221 ||
           *(const uint32_t *)(slide+0x10123e148ULL)!=0x372803c8)return;
        uint64_t *features=(void *)(slide+0x1053431a0ULL);
        if(*features!=0x401e && *features!=0x401f)return;
        uint64_t before=*features;
        *features=before|0x200000;
        fprintf(stderr,"STRAY_METAL_ABI guest_texture_buffer enabled before=0x%llx after=0x%llx native_probe=1\n",(unsigned long long)before,(unsigned long long)*features);
        return;
    }
}

static BOOL StraySupportsFeatureSet(id device,SEL selector,MTLFeatureSet feature){
    BOOL supported=NativeSupportsFeatureSet(device,selector,feature);
    if((NSUInteger)feature==10001 && TextureBufferProbePassed)StrayEnableGuestTextureBuffers();
    return supported;
}

static void StrayInstallTextureBufferCapability(id<MTLDevice> device){
    // These are the four actual texel-buffer formats used by the failing draw.
    const MTLPixelFormat formats[]={MTLPixelFormatRGBA32Float,MTLPixelFormatRGBA16Float,MTLPixelFormatRG16Float,MTLPixelFormatRGBA8Snorm};
    const NSUInteger bytesPerTexel[]={16,8,4,4};
    BOOL passed=YES;
    for(unsigned i=0;i<4;i++){
        MTLTextureDescriptor *descriptor=[MTLTextureDescriptor textureBufferDescriptorWithPixelFormat:formats[i] width:256 resourceOptions:MTLResourceStorageModeShared usage:MTLTextureUsageShaderRead];
        id<MTLBuffer> buffer=[device newBufferWithLength:16384 options:MTLResourceStorageModeShared];
        id<MTLTexture> texture=[buffer newTextureWithDescriptor:descriptor offset:0 bytesPerRow:256*bytesPerTexel[i]];
        BOOL valid=texture && texture.textureType==MTLTextureTypeTextureBuffer;
        passed=passed && valid;
        fprintf(stderr,"STRAY_METAL_ABI texture_buffer_probe format=%lu type=%lu valid=%d\n",(unsigned long)formats[i],(unsigned long)texture.textureType,valid);
    }
    TextureBufferProbePassed=passed;
    if(!passed)return;
    Class cls=object_getClass(device);SEL selector=@selector(supportsFeatureSet:);
    Method method=class_getInstanceMethod(cls,selector);
    if(!method)return;
    NativeSupportsFeatureSet=(BOOL(*)(id,SEL,MTLFeatureSet))method_getImplementation(method);
    class_replaceMethod(cls,selector,(IMP)StraySupportsFeatureSet,method_getTypeEncoding(method));
}

static void (*NativeSetStorageMode)(id,SEL,MTLStorageMode);
static void (*NativeSetResourceOptions)(id,SEL,MTLResourceOptions);
static atomic_uint StorageTranslations;
extern void StrayInstallBinkShaderBridge(id<MTLDevice> device);
extern void StrayInstallGameFrameCapture(void);
extern void StrayInstallMetalLifecycle(id<MTLDevice> device);
extern void StrayInstallMetalPipelineTiming(id<MTLDevice> device);
extern void StrayInstallMetalBufferStorage(id<MTLDevice> device);
static void (*NativeSynchronizeTexture)(id,SEL,id<MTLTexture>,NSUInteger,NSUInteger);
static void (*NativeSynchronizeResource)(id,SEL,id<MTLResource>);
static atomic_uint SharedSynchronizations;

static void StrayRecordSharedSynchronization(void){
    unsigned count=atomic_fetch_add(&SharedSynchronizations,1)+1;
    if(count<=16)fprintf(stderr,"STRAY_METAL_ABI shared_coherence_at_command_boundary %u\n",count);
}

static void StraySynchronizeTexture(id encoder,SEL selector,id<MTLTexture> texture,NSUInteger slice,NSUInteger level){
    // Shared has no separate managed CPU copy. Native Metal guarantees coherence
    // at command-buffer boundaries; UE4's submission/completion waits stay intact.
    if(texture && texture.storageMode==MTLStorageModeShared){StrayRecordSharedSynchronization();return;}
    NativeSynchronizeTexture(encoder,selector,texture,slice,level);
}

static void StraySynchronizeResource(id encoder,SEL selector,id<MTLResource> resource){
    if(resource && resource.storageMode==MTLStorageModeShared){StrayRecordSharedSynchronization();return;}
    NativeSynchronizeResource(encoder,selector,resource);
}

static void StrayInstallSharedSynchronizationBridge(id<MTLDevice> device){
    id<MTLCommandQueue> queue=[device newCommandQueue];
    id<MTLCommandBuffer> command=[queue commandBuffer];
    id<MTLBlitCommandEncoder> encoder=[command blitCommandEncoder];
    Class probeClass=object_getClass(encoder),cls=probeClass;
    SEL texture=sel_registerName("synchronizeTexture:slice:level:"),resource=sel_registerName("synchronizeResource:");
    // CaptureMTLBlitCommandEncoder forwards these Mac-only selectors without
    // exposing Methods. The observed native assertion comes from this loaded
    // implementation class; adapt its real Shared coherence path as well.
    if(!class_getInstanceMethod(cls,texture)){
        Class nativeClass=objc_lookUpClass("IOGPUMetalBlitCommandEncoder");
        if(nativeClass && class_getInstanceMethod(nativeClass,texture))cls=nativeClass;
    }
    Method textureMethod=class_getInstanceMethod(cls,texture),resourceMethod=class_getInstanceMethod(cls,resource);
    if(textureMethod){
        NativeSynchronizeTexture=(void(*)(id,SEL,id<MTLTexture>,NSUInteger,NSUInteger))method_getImplementation(textureMethod);
        class_replaceMethod(cls,texture,(IMP)StraySynchronizeTexture,method_getTypeEncoding(textureMethod));
    }
    if(resourceMethod){
        NativeSynchronizeResource=(void(*)(id,SEL,id<MTLResource>))method_getImplementation(resourceMethod);
        class_replaceMethod(cls,resource,(IMP)StraySynchronizeResource,method_getTypeEncoding(resourceMethod));
    }
    [encoder endEncoding]; // This inspection command contains no submitted GPU work.
    fprintf(stderr,"STRAY_METAL_ABI install_shared_sync class=%s probe=%s texture=%d resource=%d\n",class_getName(cls),class_getName(probeClass),textureMethod!=NULL,resourceMethod!=NULL);
}

static void StrayRecordStorageTranslation(void){
    unsigned count=atomic_fetch_add(&StorageTranslations,1)+1;
    if(count<=16)fprintf(stderr,"STRAY_METAL_ABI managed_texture_to_shared %u\n",count);
}

static void StraySetTextureStorageMode(id descriptor,SEL selector,MTLStorageMode mode){
    // Numeric 1 is macOS-only Managed. Shared preserves CPU access on the
    // native unified-memory device and reports its actual mode to the guest.
    if((NSUInteger)mode==1){mode=MTLStorageModeShared;StrayRecordStorageTranslation();}
    NativeSetStorageMode(descriptor,selector,mode);
}

static void StraySetTextureResourceOptions(id descriptor,SEL selector,MTLResourceOptions options){
    if(((options&MTLResourceStorageModeMask)>>MTLResourceStorageModeShift)==1){
        options=(options&~MTLResourceStorageModeMask)|MTLResourceStorageModeShared;
        StrayRecordStorageTranslation();
    }
    NativeSetResourceOptions(descriptor,selector,options);
}

static BOOL StrayDepth24Unsupported(id device,SEL selector){
    // MTLPixelFormatDepth24Unorm_Stencil8 (255) and its capability getter are
    // explicitly API_UNAVAILABLE(ios) in the Apple SDK. The Apple GPU format
    // table supports Depth32Float_Stencil8 instead. Let UE4 select its existing
    // supported format path; never advertise the missing format as supported.
    fprintf(stderr,"STRAY_METAL_ABI depth24_stencil8_supported 0 class=%s\n",class_getName(object_getClass(device)));
    return NO;
}

__attribute__((constructor)) static void StrayInstallMetalDeviceBridge(void){
    @autoreleasepool {
        id<MTLDevice> device=MTLCreateSystemDefaultDevice();
        if(!device)return;
        StrayInstallMetalBufferStorage(device);
        StrayInstallTextureResidencyObserver(device);
        StrayInstallTextureBufferCapability(device);
        StrayInstallBinkShaderBridge(device);
        StrayInstallMetalPipelineTiming(device);
        StrayInstallGameFrameCapture();
        StrayInstallMetalLifecycle(device);
        Class cls=object_getClass(device);SEL selector=sel_registerName("isDepth24Stencil8PixelFormatSupported");
        if(![device respondsToSelector:selector]){
            BOOL added=class_addMethod(cls,selector,(IMP)StrayDepth24Unsupported,"B@:");
            fprintf(stderr,"STRAY_METAL_ABI install_depth24_query %d gpu=%s class=%s\n",added,device.name.UTF8String,class_getName(cls));
        }
        if(device.hasUnifiedMemory){
            StrayInstallSharedSynchronizationBridge(device);
            Class descriptorClass=object_getClass([MTLTextureDescriptor new]);
            SEL storage=@selector(setStorageMode:),options=@selector(setResourceOptions:);
            Method storageMethod=class_getInstanceMethod(descriptorClass,storage);
            Method optionsMethod=class_getInstanceMethod(descriptorClass,options);
            NativeSetStorageMode=(void(*)(id,SEL,MTLStorageMode))method_getImplementation(storageMethod);
            NativeSetResourceOptions=(void(*)(id,SEL,MTLResourceOptions))method_getImplementation(optionsMethod);
            class_replaceMethod(descriptorClass,storage,(IMP)StraySetTextureStorageMode,method_getTypeEncoding(storageMethod));
            class_replaceMethod(descriptorClass,options,(IMP)StraySetTextureResourceOptions,method_getTypeEncoding(optionsMethod));
            fprintf(stderr,"STRAY_METAL_ABI install_unified_texture_storage gpu=%s unified=%d\n",device.name.UTF8String,device.hasUnifiedMemory);
        }
    }
}
