#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#import <QuartzCore/QuartzCore.h>
#import <objc/runtime.h>
#include <stdatomic.h>
#include <stdio.h>

// Opt-in timing only: pass original descriptors, options, results and errors
// through unchanged. These times measure synchronous CPU pipeline creation.
static atomic_uint PipelineCount,SlowPipelineCount;
static atomic_ullong PipelineNanoseconds;
void StrayResetPipelineTiming(void){atomic_store(&SlowPipelineCount,0);}
@interface NSObject (StrayNativePipelineTiming)
- (id<MTLRenderPipelineState>)stray_nativeRender:(MTLRenderPipelineDescriptor *)d error:(NSError **)e __attribute__((objc_method_family(new)));
- (id<MTLRenderPipelineState>)stray_nativeRender:(MTLRenderPipelineDescriptor *)d options:(MTLPipelineOption)o reflection:(MTLRenderPipelineReflection **)r error:(NSError **)e __attribute__((objc_method_family(new)));
- (id<MTLComputePipelineState>)stray_nativeCompute:(id<MTLFunction>)f error:(NSError **)e __attribute__((objc_method_family(new)));
- (id<MTLComputePipelineState>)stray_nativeCompute:(id<MTLFunction>)f options:(MTLPipelineOption)o reflection:(MTLComputePipelineReflection **)r error:(NSError **)e __attribute__((objc_method_family(new)));
- (id<MTLComputePipelineState>)stray_nativeComputeDescriptor:(MTLComputePipelineDescriptor *)d options:(MTLPipelineOption)o reflection:(MTLComputePipelineReflection **)r error:(NSError **)e __attribute__((objc_method_family(new)));
@end

static void RecordPipeline(NSString *kind,NSString *name,NSTimeInterval start,BOOL success){
    NSTimeInterval end=CACurrentMediaTime(),duration=end-start;
    unsigned count=atomic_fetch_add(&PipelineCount,1)+1;
    atomic_fetch_add(&PipelineNanoseconds,(unsigned long long)(MAX(0,duration)*1e9));
    if(duration>=0.02 && atomic_fetch_add(&SlowPipelineCount,1)<256)
        fprintf(stderr,"STRAY_PIPELINE_TIMING kind=%s function=%s elapsed_ms=%.2f success=%d count=%u total_ms=%.2f uptime=%.3f\n",
            kind.UTF8String,name.UTF8String?:"unknown",duration*1000,success,count,
            atomic_load(&PipelineNanoseconds)/1e6,end);
}

@interface StrayPipelineTimingAdapter : NSObject @end
@implementation StrayPipelineTimingAdapter
- (id<MTLRenderPipelineState>)stray_timedRender:(MTLRenderPipelineDescriptor *)d error:(NSError **)e __attribute__((objc_method_family(new))){
    NSTimeInterval start=CACurrentMediaTime();id result=[self stray_nativeRender:d error:e];
    RecordPipeline(@"render",d.fragmentFunction.name?:d.vertexFunction.name,start,result!=nil);return result;
}
- (id<MTLRenderPipelineState>)stray_timedRender:(MTLRenderPipelineDescriptor *)d options:(MTLPipelineOption)o reflection:(MTLRenderPipelineReflection **)r error:(NSError **)e __attribute__((objc_method_family(new))){
    NSTimeInterval start=CACurrentMediaTime();id result=[self stray_nativeRender:d options:o reflection:r error:e];
    RecordPipeline(@"render_reflection",d.fragmentFunction.name?:d.vertexFunction.name,start,result!=nil);return result;
}
- (id<MTLComputePipelineState>)stray_timedCompute:(id<MTLFunction>)f error:(NSError **)e __attribute__((objc_method_family(new))){
    NSTimeInterval start=CACurrentMediaTime();id result=[self stray_nativeCompute:f error:e];
    RecordPipeline(@"compute",f.name,start,result!=nil);return result;
}
- (id<MTLComputePipelineState>)stray_timedCompute:(id<MTLFunction>)f options:(MTLPipelineOption)o reflection:(MTLComputePipelineReflection **)r error:(NSError **)e __attribute__((objc_method_family(new))){
    NSTimeInterval start=CACurrentMediaTime();id result=[self stray_nativeCompute:f options:o reflection:r error:e];
    RecordPipeline(@"compute_reflection",f.name,start,result!=nil);return result;
}
- (id<MTLComputePipelineState>)stray_timedComputeDescriptor:(MTLComputePipelineDescriptor *)d options:(MTLPipelineOption)o reflection:(MTLComputePipelineReflection **)r error:(NSError **)e __attribute__((objc_method_family(new))){
    NSTimeInterval start=CACurrentMediaTime();id result=[self stray_nativeComputeDescriptor:d options:o reflection:r error:e];
    RecordPipeline(@"compute_descriptor",d.computeFunction.name,start,result!=nil);return result;
}
@end

void StrayInstallMetalPipelineTiming(id<MTLDevice> device){
    if(![NSFileManager.defaultManager fileExistsAtPath:
        [NSHomeDirectory() stringByAppendingPathComponent:@"Documents/StrayPerformanceDiagnostics"]])return;
    NSArray *selectors=@[
        @[@"newRenderPipelineStateWithDescriptor:error:",@"stray_nativeRender:error:",@"stray_timedRender:error:"],
        @[@"newRenderPipelineStateWithDescriptor:options:reflection:error:",@"stray_nativeRender:options:reflection:error:",@"stray_timedRender:options:reflection:error:"],
        @[@"newComputePipelineStateWithFunction:error:",@"stray_nativeCompute:error:",@"stray_timedCompute:error:"],
        @[@"newComputePipelineStateWithFunction:options:reflection:error:",@"stray_nativeCompute:options:reflection:error:",@"stray_timedCompute:options:reflection:error:"],
        @[@"newComputePipelineStateWithDescriptor:options:reflection:error:",@"stray_nativeComputeDescriptor:options:reflection:error:",@"stray_timedComputeDescriptor:options:reflection:error:"]];
    Class cls=object_getClass(device);unsigned installed=0;
    for(NSArray *entry in selectors){
        SEL native=NSSelectorFromString(entry[0]),saved=NSSelectorFromString(entry[1]);
        Method method=class_getInstanceMethod(cls,native),timed=class_getInstanceMethod(StrayPipelineTimingAdapter.class,NSSelectorFromString(entry[2]));
        if(!method || !timed || !class_addMethod(cls,saved,method_getImplementation(method),method_getTypeEncoding(method)))continue;
        class_replaceMethod(cls,native,method_getImplementation(timed),method_getTypeEncoding(method));installed++;
    }
    fprintf(stderr,"STRAY_PIPELINE_TIMING installed=%u class=%s\n",installed,class_getName(cls));
}
