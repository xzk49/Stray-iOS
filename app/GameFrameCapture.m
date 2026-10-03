#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <Metal/Metal.h>
#import <QuartzCore/CAMetalLayer.h>
#import <objc/runtime.h>
#include <mach-o/dyld.h>
#include <mach-o/loader.h>
#include <string.h>
#include <stdatomic.h>
#include <stdio.h>
#include <mach/mach.h>
#include <stdlib.h>

@interface CAMetalLayer (StrayNativeDrawable)
- (id<CAMetalDrawable>)stray_nativeNextDrawable;
@end
@interface StrayGameFrameObserver : NSObject
- (id<CAMetalDrawable>)stray_nextDrawable;
@end

static atomic_uint GameDrawables;
static atomic_uint PresentedFrames;
static atomic_bool ExplicitFrameRequest;
static NSTimeInterval LastRateTime;
static unsigned LastRateCount;
static NSTimeInterval LastDrawableEnd;
static unsigned LastDrawableEpoch,StallMessages;
static BOOL PerformanceDiagnostics;
static double FrameIntervals[300];
static unsigned IntervalCount;
static unsigned RateEpoch;
static char GameFrameNumberKey,PresentTimingKey;
static atomic_uint TimingGeneration;
static unsigned LastTimingGeneration;
static NSObject *TimingLock;
static double PresentGPUSum,PresentGPUMax;
static unsigned PresentGPUCount;
extern void StrayResetPipelineTiming(void);
void StrayResetPerformanceTiming(void){
    atomic_fetch_add(&TimingGeneration,1);
    @synchronized(TimingLock){PresentGPUSum=0;PresentGPUMax=0;PresentGPUCount=0;}
    StrayResetPipelineTiming();fprintf(stderr,"STRAY_PERFORMANCE reset=1 generation=%u\n",atomic_load(&TimingGeneration));
}
static int CompareIntervals(const void *a,const void *b){double x=*(const double *)a,y=*(const double *)b;return (x>y)-(x<y);}
static void RecordPresentGPU(id<MTLCommandBuffer> command,id<CAMetalDrawable> drawable){
    if(!PerformanceDiagnostics || !objc_getAssociatedObject(drawable,&GameFrameNumberKey) || objc_getAssociatedObject(command,&PresentTimingKey))return;
    objc_setAssociatedObject(command,&PresentTimingKey,@YES,OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    unsigned generation=atomic_load(&TimingGeneration);
    [command addCompletedHandler:^(id<MTLCommandBuffer> completed){
        double duration=(completed.GPUEndTime-completed.GPUStartTime)*1000;
        if(completed.status==MTLCommandBufferStatusCompleted && duration>0 && generation==atomic_load(&TimingGeneration)){
            @synchronized(TimingLock){PresentGPUSum+=duration;PresentGPUMax=MAX(PresentGPUMax,duration);PresentGPUCount++;}
        }
    }];
}
static unsigned CaptureStopAt;
static NSURL *CapturedTraceURL;
static NSObject *CaptureLock;
static char ReadbackFrameKey;
static void (*NativePresent)(id,SEL,id<MTLDrawable>);
static void (*NativePresentAtTime)(id,SEL,id<MTLDrawable>,CFTimeInterval);
static void (*NativePresentAfterDuration)(id,SEL,id<MTLDrawable>,CFTimeInterval);
static void (*NativeAddScheduledHandler)(id,SEL,MTLCommandBufferHandler);
static uintptr_t GuestScheduledWrapper,GuestPresentBlock;
extern void StrayArchiveTracePreservingLinks(NSURL *trace);
extern void StrayProcessTraceCleanupRequest(void);
extern void StrayProcessRenderTestRequest(unsigned frame);
extern void StrayProcessThermalPacing(unsigned frame);
extern unsigned StrayMetalLifecycleEpoch(void);

static void ArchiveCapturedTrace(NSURL *trace){
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY,0),^{ @autoreleasepool {
        NSFileManager *files=NSFileManager.defaultManager;
        if([files fileExistsAtPath:[trace.path stringByAppendingString:@".tar"]])return;
        if(![files fileExistsAtPath:[trace.path stringByAppendingPathComponent:@"index"]]){
            fprintf(stderr,"STRAY_MODEL_CAPTURE incomplete file=%s missing=index\n",trace.lastPathComponent.UTF8String);return;
        }
        // Preserve resource aliases directly, without another full temporary ZIP
        // copy. Coordinated upload failed even for intact aliases on this device.
        StrayArchiveTracePreservingLinks(trace);
        if([files fileExistsAtPath:[trace.path stringByAppendingString:@".tar"]])return;
        NSURL *archive=[NSURL fileURLWithPath:[trace.path stringByAppendingString:@".zip"]];
        if([NSFileManager.defaultManager fileExistsAtPath:archive.path])return;
        // CoreDevice refuses individual symbolic-link resource versions in a
        // trace bundle. Apple's coordinated upload packages them into one ZIP.
        NSFileCoordinator *coordinator=[[NSFileCoordinator alloc] initWithFilePresenter:nil];
        NSError *error=nil;__block NSError *copyError=nil;__block BOOL saved=NO;
        [coordinator coordinateReadingItemAtURL:trace options:NSFileCoordinatorReadingForUploading error:&error byAccessor:^(NSURL *upload){
            NSNumber *regular=nil;[upload getResourceValue:&regular forKey:NSURLIsRegularFileKey error:&copyError];
            if(regular.boolValue)saved=[NSFileManager.defaultManager copyItemAtURL:upload toURL:archive error:&copyError];
        }];
        fprintf(stderr,"STRAY_MODEL_CAPTURE archive file=%s saved=%d error=%s\n",archive.lastPathComponent.UTF8String,saved,(error?:copyError).description.UTF8String?:"none");
        if(!saved)StrayArchiveTracePreservingLinks(trace);
    }});
}

static void StopModelCapture(unsigned count,const char *reason){
    @synchronized(CaptureLock){
        if(!CaptureStopAt)return;
        [MTLCaptureManager.sharedCaptureManager stopCapture];CaptureStopAt=0;
        fprintf(stderr,"STRAY_MODEL_CAPTURE ended drawable=%u reason=%s\n",count,reason);
        if(CapturedTraceURL)ArchiveCapturedTrace(CapturedTraceURL);
    }
}

static void CheckModelCaptureRequest(CAMetalLayer *layer,unsigned count){
    @synchronized(CaptureLock){
    NSString *documents=[NSHomeDirectory() stringByAppendingPathComponent:@"Documents"];
    if(count%60==0){
        StrayProcessThermalPacing(count);
        StrayProcessTraceCleanupRequest();
        StrayProcessRenderTestRequest(count);
        NSString *frameRequest=[documents stringByAppendingPathComponent:@"StrayFrameRequest"];
        if([NSFileManager.defaultManager fileExistsAtPath:frameRequest]){
            [NSFileManager.defaultManager removeItemAtPath:frameRequest error:nil];
            atomic_store(&ExplicitFrameRequest,true);
        }
    }
    MTLCaptureManager *manager=MTLCaptureManager.sharedCaptureManager;
    if(CaptureStopAt || count%60)return;
    NSString *request=[documents stringByAppendingPathComponent:@"StrayCaptureRequest"];
    if(![NSFileManager.defaultManager fileExistsAtPath:request])return;
    [NSFileManager.defaultManager removeItemAtPath:request error:nil];
    if(![manager supportsDestination:MTLCaptureDestinationGPUTraceDocument]){
        fprintf(stderr,"STRAY_MODEL_CAPTURE unsupported destination; MetalCaptureEnabled required\n");return;
    }
    MTLCaptureDescriptor *descriptor=[MTLCaptureDescriptor new];
    descriptor.captureObject=layer.device;
    descriptor.destination=MTLCaptureDestinationGPUTraceDocument;
    NSString *name=[NSString stringWithFormat:@"StrayModelDebug-%06u.gputrace",count];
    descriptor.outputURL=[NSURL fileURLWithPath:[documents stringByAppendingPathComponent:name]];
    NSError *error=nil;BOOL started=[manager startCaptureWithDescriptor:descriptor error:&error];
    if(started){
        // UE requests the display drawable partway through its render frame.
        // Ending at the next acquisition omitted that frame's base pass. Wait
        // for the following drawable to be displayed, after GPU submission.
        CaptureStopAt=count+1;CapturedTraceURL=descriptor.outputURL;
        NSURL *trace=descriptor.outputURL;
        // A stalled/backgrounded game may never request another drawable.
        // Bound diagnostics independently of the game's render loop.
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW,4*NSEC_PER_SEC),dispatch_get_global_queue(QOS_CLASS_UTILITY,0),^{
            @synchronized(CaptureLock){if(CapturedTraceURL==trace)StopModelCapture(count,"deadline");}
        });
    }
    fprintf(stderr,"STRAY_MODEL_CAPTURE begin drawable=%u file=%s accepted=%d error=%s\n",count,name.UTF8String,started,error.description.UTF8String?:"none");
    }
}

static void ReadGameFrameBeforePresent(id<MTLCommandBuffer> command,id<CAMetalDrawable> drawable){
    RecordPresentGPU(command,drawable);
    NSNumber *requested=objc_getAssociatedObject(drawable,&ReadbackFrameKey);
    if(!requested)return;
    objc_setAssociatedObject(drawable,&ReadbackFrameKey,nil,OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    unsigned frame=requested.unsignedIntValue;
    id<MTLTexture> texture=drawable.texture;
    NSUInteger width=texture.width,height=texture.height;
    if(texture.framebufferOnly || !width || !height || width>4096 || height>4096 ||
       (texture.pixelFormat!=MTLPixelFormatBGRA8Unorm && texture.pixelFormat!=MTLPixelFormatBGRA8Unorm_sRGB)){
        fprintf(stderr,"STRAY_GAME_FRAME capture_unavailable frame=%u format=%lu framebuffer_only=%d size=%lux%lu\n",
           frame,(unsigned long)texture.pixelFormat,texture.framebufferOnly,(unsigned long)width,(unsigned long)height);return;
    }
    NSUInteger stride=(width*4+255)&~(NSUInteger)255,length=stride*height;
    id<MTLBuffer> pixels=[texture.device newBufferWithLength:length options:MTLResourceStorageModeShared];
    // Encode after UE4's render encoders, in the same command buffer and before
    // display presentation can discard/reuse the drawable's contents.
    id<MTLBlitCommandEncoder> encoder=[command blitCommandEncoder];
    [encoder copyFromTexture:texture sourceSlice:0 sourceLevel:0 sourceOrigin:MTLOriginMake(0,0,0)
         sourceSize:MTLSizeMake(width,height,1) toBuffer:pixels destinationOffset:0
         destinationBytesPerRow:stride destinationBytesPerImage:length];
    [encoder endEncoding];
    fprintf(stderr,"STRAY_GAME_FRAME readback_encoded frame=%u before_present=1\n",frame);
    [command addCompletedHandler:^(id<MTLCommandBuffer> completed){ @autoreleasepool {
        if(completed.status!=MTLCommandBufferStatusCompleted){
            fprintf(stderr,"STRAY_GAME_FRAME gpu_readback_failed %s\n",completed.error.description.UTF8String);return;
        }
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY,0),^{ @autoreleasepool {
        const unsigned char *bytes=pixels.contents;unsigned maxima[4]={0};
        for(NSUInteger y=0;y<height;y++)for(NSUInteger x=0;x<width;x++)for(unsigned c=0;c<4;c++)
            if(bytes[y*stride+x*4+c]>maxima[c])maxima[c]=bytes[y*stride+x*4+c];
        fprintf(stderr,"STRAY_GAME_FRAME raw_channels frame=%u bgra_max=%u,%u,%u,%u\n",frame,maxima[0],maxima[1],maxima[2],maxima[3]);
        CGColorSpaceRef color=CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
        // This game layer displays opaque color. UE4's scene tonemap writes
        // zero alpha; interpreting it as premultiplied erased valid RGB data.
        CGContextRef context=CGBitmapContextCreate(pixels.contents,width,height,8,stride,color,
             kCGBitmapByteOrder32Little|kCGImageAlphaNoneSkipFirst);
        CGImageRef image=context?CGBitmapContextCreateImage(context):NULL;
        NSData *png=image?UIImagePNGRepresentation([UIImage imageWithCGImage:image]):nil;
        NSString *name=[NSString stringWithFormat:@"StrayGameFrame-%06u.png",frame];
        NSString *path=[[NSHomeDirectory() stringByAppendingPathComponent:@"Documents"] stringByAppendingPathComponent:name];
        NSError *error=nil;BOOL saved=[png writeToFile:path options:NSDataWritingAtomic error:&error];
        fprintf(stderr,"STRAY_GAME_FRAME captured frame=%u file=%s size=%lux%lu saved=%d error=%s\n",
            frame,name.UTF8String,(unsigned long)width,(unsigned long)height,saved,error.description.UTF8String?:"none");
        if(image)CGImageRelease(image);if(context)CGContextRelease(context);CGColorSpaceRelease(color);
        }});
        (void)drawable;
    }}];
}

static void PresentGameFrame(id command,SEL selector,id<MTLDrawable> drawable){
    ReadGameFrameBeforePresent(command,(id)drawable);NativePresent(command,selector,drawable);
}
static void PresentGameFrameAtTime(id command,SEL selector,id<MTLDrawable> drawable,CFTimeInterval time){
    ReadGameFrameBeforePresent(command,(id)drawable);NativePresentAtTime(command,selector,drawable,time);
}
static void PresentGameFrameAfterDuration(id command,SEL selector,id<MTLDrawable> drawable,CFTimeInterval duration){
    ReadGameFrameBeforePresent(command,(id)drawable);NativePresentAfterDuration(command,selector,drawable,duration);
}

static void ResolveGuestPresentBlocks(void){
    if(GuestPresentBlock)return;
    const unsigned char expected[16]={0xb2,0x3c,0xfb,0xe6,0x80,0xd4,0x32,0xaa,0x96,0x75,0x5f,0x9a,0x5e,0xd4,0x53,0xde};
    for(uint32_t i=0;i<_dyld_image_count();i++){
        const char *name=_dyld_get_image_name(i);if(!name || !strstr(name,"/StrayGuest.dylib"))continue;
        const struct mach_header_64 *header=(const void *)_dyld_get_image_header(i);
        if(header->magic!=MH_MAGIC_64)return;
        const struct load_command *lc=(const void *)(header+1);BOOL match=NO;
        for(uint32_t j=0;j<header->ncmds;j++){
            if(lc->cmd==LC_UUID)match=!memcmp(((const struct uuid_command *)lc)->uuid,expected,16);
            lc=(const void *)((const char *)lc+lc->cmdsize);
        }
        if(!match)return;
        intptr_t slide=_dyld_get_image_vmaddr_slide(i);
        if(*(const uint32_t *)(slide+0x101241bf4ULL)!=0xf9401000 ||
           *(const uint32_t *)(slide+0x101241bf8ULL)!=0x14a9482d ||
           *(const uint32_t *)(slide+0x1000ce1f0ULL)!=0xf9401260)return;
        GuestScheduledWrapper=slide+0x1000ce1ccULL;GuestPresentBlock=slide+0x101241bf4ULL;return;
    }
}

static void AddGameScheduledHandler(id command,SEL selector,MTLCommandBufferHandler handler){
    // The audited Mac viewport presents the drawable from a scheduled block,
    // rather than calling presentDrawable: on its command buffer. mtlpp wraps
    // that block once. Recognize both original invoke addresses before reading
    // their audited capture fields; all other handlers pass through unchanged.
    ResolveGuestPresentBlocks();
    const uintptr_t *outer=(__bridge const void *)handler;
    if(GuestScheduledWrapper && outer && outer[2]==GuestScheduledWrapper){
        const uintptr_t *inner=(const void *)outer[4];
        if(inner && inner[2]==GuestPresentBlock){
            id<CAMetalDrawable> drawable=(__bridge id)(const void *)inner[4];
            ReadGameFrameBeforePresent(command,drawable);
        }
    }
    NativeAddScheduledHandler(command,selector,handler);
}

static void InstallPresentReadback(void){
    id<MTLCommandQueue> queue=[MTLCreateSystemDefaultDevice() newCommandQueue];
    id<MTLCommandBuffer> command=[queue commandBuffer];Class cls=object_getClass(command);
    Method method=class_getInstanceMethod(cls,@selector(presentDrawable:));
    if(method){NativePresent=(void *)method_getImplementation(method);class_replaceMethod(cls,@selector(presentDrawable:),(IMP)PresentGameFrame,method_getTypeEncoding(method));}
    method=class_getInstanceMethod(cls,@selector(presentDrawable:atTime:));
    if(method){NativePresentAtTime=(void *)method_getImplementation(method);class_replaceMethod(cls,@selector(presentDrawable:atTime:),(IMP)PresentGameFrameAtTime,method_getTypeEncoding(method));}
    method=class_getInstanceMethod(cls,@selector(presentDrawable:afterMinimumDuration:));
    if(method){NativePresentAfterDuration=(void *)method_getImplementation(method);class_replaceMethod(cls,@selector(presentDrawable:afterMinimumDuration:),(IMP)PresentGameFrameAfterDuration,method_getTypeEncoding(method));}
    method=class_getInstanceMethod(cls,@selector(addScheduledHandler:));
    if(method){NativeAddScheduledHandler=(void *)method_getImplementation(method);class_replaceMethod(cls,@selector(addScheduledHandler:),(IMP)AddGameScheduledHandler,method_getTypeEncoding(method));}
    fprintf(stderr,"STRAY_GAME_FRAME present_observer class=%s direct=%d timed=%d duration=%d scheduled=%d\n",class_getName(cls),NativePresent!=NULL,NativePresentAtTime!=NULL,NativePresentAfterDuration!=NULL,NativeAddScheduledHandler!=NULL);
}

@implementation StrayGameFrameObserver
- (id<CAMetalDrawable>)stray_nextDrawable {
    CAMetalLayer *layer=(id)self;
    BOOL game=[layer.name isEqualToString:@"StrayGuestMetalLayer"];
    NSTimeInterval acquireStart=PerformanceDiagnostics && game?CACurrentMediaTime():0;
    unsigned epoch=StrayMetalLifecycleEpoch();
    id<CAMetalDrawable> drawable=[layer stray_nativeNextDrawable];
    if(drawable && game){
        unsigned count=atomic_fetch_add(&GameDrawables,1)+1;
        unsigned generation=atomic_load(&TimingGeneration);
        if(LastTimingGeneration!=generation){LastTimingGeneration=generation;LastDrawableEnd=0;LastRateTime=0;StallMessages=0;@synchronized(TimingLock){IntervalCount=0;}}
        objc_setAssociatedObject(drawable,&GameFrameNumberKey,@(count),OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        if(PerformanceDiagnostics){
            NSTimeInterval end=CACurrentMediaTime();
            double gap=LastDrawableEnd?acquireStart-LastDrawableEnd:0,wait=end-acquireStart;
            if(LastDrawableEnd && epoch==LastDrawableEpoch && epoch==StrayMetalLifecycleEpoch()){
                @synchronized(TimingLock){FrameIntervals[IntervalCount++%300]=(end-LastDrawableEnd)*1000;}
            }
            if(count>600 && epoch==LastDrawableEpoch && epoch==StrayMetalLifecycleEpoch() &&
               (gap>0.15 || wait>0.15) && StallMessages++<256){
                task_vm_info_data_t memory={0};mach_msg_type_number_t size=TASK_VM_INFO_COUNT;
                kern_return_t status=task_info(mach_task_self(),TASK_VM_INFO,(task_info_t)&memory,&size);
                fprintf(stderr,"STRAY_FRAME_STALL frame=%u gap_ms=%.2f drawable_wait_ms=%.2f footprint_mb=%.1f uptime=%.3f\n",
                    count,gap*1000,wait*1000,status==KERN_SUCCESS?memory.phys_footprint/1048576.0:-1.0,end);
            }
            LastDrawableEnd=end;LastDrawableEpoch=epoch;
        }
        if(count==1 || !LastRateTime || RateEpoch!=epoch){LastRateTime=NSProcessInfo.processInfo.systemUptime;LastRateCount=count;RateEpoch=epoch;}
        if(count%300==0){
            NSTimeInterval now=NSProcessInfo.processInfo.systemUptime;
            task_vm_info_data_t memory={0};mach_msg_type_number_t size=TASK_VM_INFO_COUNT;
            kern_return_t status=task_info(mach_task_self(),TASK_VM_INFO,(task_info_t)&memory,&size);
            fprintf(stderr,"STRAY_RENDER_HEALTH frames=%u submit_fps=%.2f footprint_mb=%.1f\n",count,(count-LastRateCount)/MAX(0.001,now-LastRateTime),status==KERN_SUCCESS?memory.phys_footprint/1048576.0:-1.0);
            if(PerformanceDiagnostics){@synchronized(TimingLock){unsigned n=MIN(IntervalCount,300);if(n){double samples[300];memcpy(samples,FrameIntervals,n*sizeof(double));qsort(samples,n,sizeof(double),CompareIntervals);
                NSDictionary *report=@{@"frame":@(count),@"width":@(drawable.texture.width),@"height":@(drawable.texture.height),@"samples":@(n),@"submitFPS":@((count-LastRateCount)/MAX(.001,now-LastRateTime)),
                    @"thermalState":@(NSProcessInfo.processInfo.thermalState),
                    @"p50MS":@(samples[(n-1)/2]),@"p95MS":@(samples[(n-1)*95/100]),@"p99MS":@(samples[(n-1)*99/100]),@"maxMS":@(samples[n-1]),@"footprintMB":@(memory.phys_footprint/1048576.0),
                    @"presentCommandGPUCount":@(PresentGPUCount),@"presentCommandGPUAverageMS":@(PresentGPUCount?PresentGPUSum/PresentGPUCount:0),@"presentCommandGPUMaxMS":@(PresentGPUMax),@"generation":@(atomic_load(&TimingGeneration))};
                NSData *data=[NSJSONSerialization dataWithJSONObject:report options:NSJSONWritingPrettyPrinted error:nil];
                [data writeToFile:[NSHomeDirectory() stringByAppendingPathComponent:@"Documents/StrayPerformance.json"] atomically:YES];
                fprintf(stderr,"STRAY_FRAME_TIMING frame=%u samples=%u p50_ms=%.2f p95_ms=%.2f max_ms=%.2f size=%lux%lu\n",count,n,samples[(n-1)/2],samples[(n-1)*95/100],samples[n-1],(unsigned long)drawable.texture.width,(unsigned long)drawable.texture.height);
            }}}
            LastRateTime=now;LastRateCount=count;
        }
        CheckModelCaptureRequest(layer,count);
        BOOL requested=atomic_exchange(&ExplicitFrameRequest,false);
        if(requested || count==1 || count==30 || count==120 || count==600 || count==1800)
            objc_setAssociatedObject(drawable,&ReadbackFrameKey,@(count),OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        if(count<=3 || count%300==0)fprintf(stderr,"STRAY_GAME_FRAME drawable count=%u size=%lux%lu\n",
           count,(unsigned long)drawable.texture.width,(unsigned long)drawable.texture.height);
        [drawable addPresentedHandler:^(id<MTLDrawable> presented){ @autoreleasepool {
            unsigned frame=atomic_fetch_add(&PresentedFrames,1)+1;
            if(frame<=3 || frame%300==0)fprintf(stderr,"STRAY_GAME_FRAME presented count=%u time=%.6f\n",frame,presented.presentedTime);
            @synchronized(CaptureLock){
                if(CaptureStopAt && count>=CaptureStopAt)StopModelCapture(count,"presented_drawable");
            }
        }}];
    }
    return drawable;
}
@end

void StrayInstallGameFrameCapture(void){
    TimingLock=[NSObject new];
    PerformanceDiagnostics=[NSFileManager.defaultManager fileExistsAtPath:
        [NSHomeDirectory() stringByAppendingPathComponent:@"Documents/StrayPerformanceDiagnostics"]];
    CaptureLock=[NSObject new];InstallPresentReadback();
    StrayProcessTraceCleanupRequest();
    Class cls=CAMetalLayer.class;SEL native=@selector(nextDrawable);
    Method method=class_getInstanceMethod(cls,native);
    if(!class_addMethod(cls,@selector(stray_nativeNextDrawable),method_getImplementation(method),method_getTypeEncoding(method)))return;
    Method observer=class_getInstanceMethod(StrayGameFrameObserver.class,@selector(stray_nextDrawable));
    class_replaceMethod(cls,native,method_getImplementation(observer),method_getTypeEncoding(method));
    fprintf(stderr,"STRAY_GAME_FRAME observer_installed\n");
    NSString *documents=[NSHomeDirectory() stringByAppendingPathComponent:@"Documents"];
    for(NSString *name in [NSFileManager.defaultManager contentsOfDirectoryAtPath:documents error:nil])
        if([name hasPrefix:@"StrayModelDebug-"] && [name hasSuffix:@".gputrace"])
            ArchiveCapturedTrace([NSURL fileURLWithPath:[documents stringByAppendingPathComponent:name]]);
}
