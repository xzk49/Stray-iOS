#import <Foundation/Foundation.h>
#import <AVFAudio/AVFAudio.h>
#import <AudioToolbox/AudioToolbox.h>
#import <UIKit/UIKit.h>
#include <dlfcn.h>
#include <stdatomic.h>
#include <math.h>

// These three-field HAL addresses have the same ABI on Mac and iOS. Desktop
// Native default-output IDs can be returned even when desktop buffer-size
// properties on that ID are unsupported. Remember that actual route ID;
// fallback ID 2 is used only if the default-output query itself is unavailable.
typedef struct { UInt32 selector,scope,element; } StrayAudioAddress;
static OSStatus (*NativeGet)(UInt32,const StrayAudioAddress *,UInt32,const void *,UInt32 *,void *);
static OSStatus (*NativeSet)(UInt32,const StrayAudioAddress *,UInt32,const void *,UInt32,const void *);
static OSStatus (*NativeAddNode)(AUGraph,const AudioComponentDescription *,AUNode *);
static OSStatus (*NativeCallback)(AUGraph,AUNode,UInt32,const AURenderCallbackStruct *);
static OSStatus (*NativeStart)(AUGraph);
static OSStatus (*NativeStop)(AUGraph);
static OSStatus (*NativeDispose)(AUGraph);
static NSMutableDictionary *Graphs;
static atomic_ullong Callbacks,NonzeroCallbacks,Samples;
static atomic_uint PeakMillionths,RenderErrors;
static atomic_uint DefaultOutputID;
static dispatch_source_t Meter;

@interface StrayAudioGraph : NSObject { @public AURenderCallbackStruct renderCallback; }
@property(nonatomic) AUGraph graph;
@property(nonatomic) BOOL wantedRunning;
@property(nonatomic) BOOL pausedForLifecycle;
@end
@implementation StrayAudioGraph @end

static BOOL ActivateSession(void){
    AVAudioSession *session=AVAudioSession.sharedInstance;NSError *error=nil;
    BOOL ok=[session setCategory:AVAudioSessionCategoryPlayback mode:AVAudioSessionModeDefault options:0 error:&error];
    if(ok)ok=[session setPreferredSampleRate:48000 error:&error];
    if(ok)ok=[session setPreferredIOBufferDuration:1024.0/48000 error:&error];
    if(ok)ok=[session setActive:YES error:&error];
    fprintf(stderr,"STRAY_AUDIO session active=%d rate=%.0f duration=%.6f channels=%lu route=%s error=%s\n",ok,session.sampleRate,session.IOBufferDuration,(unsigned long)session.outputNumberOfChannels,session.currentRoute.description.UTF8String,error.description.UTF8String?:"none");
    return ok;
}

OSStatus StrayAudioObjectGetPropertyData(UInt32 object,const StrayAudioAddress *address,UInt32 qualifierSize,const void *qualifier,UInt32 *size,void *data){
    UInt32 capacity=size?*size:0;
    OSStatus status=NativeGet?NativeGet(object,address,qualifierSize,qualifier,size,data):-1;
    // iOS HAL does not promise the desktop default-output/buffer selectors.
    // Implement only the audited queries that the game's mixer actually uses.
    if(status && address && size && data){
        if(object==1 && address->selector=='dOut' && capacity>=4){*(UInt32 *)data=2;*size=4;status=0;}
        else if(object==atomic_load(&DefaultOutputID) && object && address->selector=='fsiz' && capacity>=4){
            AVAudioSession *s=AVAudioSession.sharedInstance;*(UInt32 *)data=(UInt32)llround(s.IOBufferDuration*s.sampleRate);*size=4;status=0;
        }else if(object==atomic_load(&DefaultOutputID) && object && address->selector=='nsrt' && capacity>=8){*(Float64 *)data=AVAudioSession.sharedInstance.sampleRate;*size=8;status=0;}
    }
    if(!status && object==1 && address && address->selector=='dOut' && size && *size==4 && data)atomic_store(&DefaultOutputID,*(UInt32 *)data);
    if(address)fprintf(stderr,"STRAY_AUDIO hal_get object=%u selector=%08x size=%u status=%d\n",object,address->selector,size?*size:0,(int)status);
    return status;
}
OSStatus StrayAudioObjectSetPropertyData(UInt32 object,const StrayAudioAddress *address,UInt32 qualifierSize,const void *qualifier,UInt32 size,const void *data){
    OSStatus status=NativeSet?NativeSet(object,address,qualifierSize,qualifier,size,data):-1;
    if(status && object && object==atomic_load(&DefaultOutputID) && address && address->selector=='fsiz' && size==4 && data){
        UInt32 frames=*(const UInt32 *)data;NSError *error=nil;
        AVAudioSession *session=AVAudioSession.sharedInstance;
        if(frames>=64 && frames<=4096 && session.sampleRate>0){
            status=[session setPreferredIOBufferDuration:frames/session.sampleRate error:&error]?0:(OSStatus)-1;
            fprintf(stderr,"STRAY_AUDIO buffer_request object=%u frames=%u actual_duration=%.6f status=%d error=%s\n",object,frames,session.IOBufferDuration,(int)status,error.description.UTF8String?:"none");
        }
    }
    if(address)fprintf(stderr,"STRAY_AUDIO hal_set object=%u selector=%08x status=%d\n",object,address->selector,(int)status);
    return status;
}

OSStatus StrayAUGraphAddNode(AUGraph graph,const AudioComponentDescription *description,AUNode *node){
    AudioComponentDescription translated=description?*description:(AudioComponentDescription){0};
    BOOL output=translated.componentType==kAudioUnitType_Output && translated.componentSubType=='def ';
    if(output){ActivateSession();translated.componentSubType=kAudioUnitSubType_RemoteIO;}
    OSStatus status=NativeAddNode(graph,&translated,node);
    if(output && !status){@synchronized(Graphs){StrayAudioGraph *value=[StrayAudioGraph new];value.graph=graph;Graphs[[NSValue valueWithPointer:graph]]=value;}}
    fprintf(stderr,"STRAY_AUDIO graph_node type=%08x subtype=%08x native_subtype=%08x status=%d\n",description?description->componentType:0,description?description->componentSubType:0,translated.componentSubType,(int)status);
    return status;
}

static OSStatus RenderAudio(void *context,AudioUnitRenderActionFlags *flags,const AudioTimeStamp *time,UInt32 bus,UInt32 frames,AudioBufferList *buffers){
    // No allocations, locks, file IO or Objective-C sends on the realtime path.
    __unsafe_unretained StrayAudioGraph *value=(__bridge StrayAudioGraph *)context;
    AURenderCallbackStruct callback=value->renderCallback;
    OSStatus status=callback.inputProc(callback.inputProcRefCon,flags,time,bus,frames,buffers);
    atomic_fetch_add_explicit(&Callbacks,1,memory_order_relaxed);
    if(status)atomic_fetch_add_explicit(&RenderErrors,1,memory_order_relaxed);
    float peak=0;unsigned long long samples=0;
    if(!status && buffers)for(UInt32 b=0;b<buffers->mNumberBuffers;b++){
        const float *pcm=buffers->mBuffers[b].mData;UInt32 count=buffers->mBuffers[b].mDataByteSize/sizeof(float);
        if(!pcm)continue;samples+=count;
        for(UInt32 i=0;i<count;i++){float v=fabsf(pcm[i]);if(isfinite(v)&&v>peak)peak=v;}
    }
    atomic_fetch_add_explicit(&Samples,samples,memory_order_relaxed);
    if(peak>0.00001f)atomic_fetch_add_explicit(&NonzeroCallbacks,1,memory_order_relaxed);
    unsigned p=(unsigned)(fminf(peak,4)*1000000),old=atomic_load_explicit(&PeakMillionths,memory_order_relaxed);
    while(p>old && !atomic_compare_exchange_weak_explicit(&PeakMillionths,&old,p,memory_order_relaxed,memory_order_relaxed)){}
    return status;
}

OSStatus StrayAUGraphSetNodeInputCallback(AUGraph graph,AUNode node,UInt32 input,const AURenderCallbackStruct *callback){
    StrayAudioGraph *value;@synchronized(Graphs){value=Graphs[[NSValue valueWithPointer:graph]];}
    if(value && callback && callback->inputProc){
        value->renderCallback=*callback;AURenderCallbackStruct wrapper={RenderAudio,(__bridge void *)value};
        OSStatus status=NativeCallback(graph,node,input,&wrapper);
        fprintf(stderr,"STRAY_AUDIO mixer_callback installed=%d\n",status==0);return status;
    }
    return NativeCallback(graph,node,input,callback);
}
OSStatus StrayAUGraphStart(AUGraph graph){
    ActivateSession();OSStatus status=NativeStart(graph);
    @synchronized(Graphs){StrayAudioGraph *value=Graphs[[NSValue valueWithPointer:graph]];value.wantedRunning=status==0;value.pausedForLifecycle=NO;}
    fprintf(stderr,"STRAY_AUDIO graph_start status=%d\n",(int)status);return status;
}
OSStatus StrayAUGraphStop(AUGraph graph){
    @synchronized(Graphs){StrayAudioGraph *value=Graphs[[NSValue valueWithPointer:graph]];value.wantedRunning=NO;value.pausedForLifecycle=NO;}
    return NativeStop(graph);
}
OSStatus StrayDisposeAUGraph(AUGraph graph){
    OSStatus status=NativeDispose(graph);if(!status)@synchronized(Graphs){[Graphs removeObjectForKey:[NSValue valueWithPointer:graph]];}return status;
}

static void PauseGraphs(BOOL paused){
    if(!paused && !ActivateSession())return;
    @synchronized(Graphs){for(StrayAudioGraph *value in Graphs.allValues){
        if(paused && value.wantedRunning && !value.pausedForLifecycle){OSStatus status=NativeStop(value.graph);value.pausedForLifecycle=status==0;fprintf(stderr,"STRAY_AUDIO lifecycle_stop status=%d\n",(int)status);}
        if(!paused && value.wantedRunning && value.pausedForLifecycle){OSStatus status=NativeStart(value.graph);value.pausedForLifecycle=status!=0;fprintf(stderr,"STRAY_AUDIO lifecycle_resume status=%d\n",(int)status);}
    }}
}
__attribute__((constructor))static void SetupAudio(void){
    Graphs=[NSMutableDictionary new];
    void *hal=dlopen("/System/Library/Frameworks/CoreAudio.framework/CoreAudio",RTLD_NOW|RTLD_LOCAL);
    void *audio=dlopen("/System/Library/Frameworks/AudioToolbox.framework/AudioToolbox",RTLD_NOW|RTLD_LOCAL);
    NativeGet=dlsym(hal,"AudioObjectGetPropertyData");NativeSet=dlsym(hal,"AudioObjectSetPropertyData");
    NativeAddNode=dlsym(audio,"AUGraphAddNode");NativeCallback=dlsym(audio,"AUGraphSetNodeInputCallback");
    NativeStart=dlsym(audio,"AUGraphStart");NativeStop=dlsym(audio,"AUGraphStop");NativeDispose=dlsym(audio,"DisposeAUGraph");
    [NSNotificationCenter.defaultCenter addObserverForName:UIApplicationWillResignActiveNotification object:nil queue:nil usingBlock:^(NSNotification *n){PauseGraphs(YES);}];
    [NSNotificationCenter.defaultCenter addObserverForName:UIApplicationDidBecomeActiveNotification object:nil queue:nil usingBlock:^(NSNotification *n){PauseGraphs(NO);}];
    [NSNotificationCenter.defaultCenter addObserverForName:AVAudioSessionInterruptionNotification object:nil queue:nil usingBlock:^(NSNotification *n){PauseGraphs([n.userInfo[AVAudioSessionInterruptionTypeKey] unsignedIntegerValue]==AVAudioSessionInterruptionTypeBegan);}];
    Meter=dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER,0,0,dispatch_get_global_queue(QOS_CLASS_UTILITY,0));
    dispatch_source_set_timer(Meter,dispatch_time(DISPATCH_TIME_NOW,10*NSEC_PER_SEC),10*NSEC_PER_SEC,NSEC_PER_SEC);
    dispatch_source_set_event_handler(Meter,^{fprintf(stderr,"STRAY_AUDIO pcm callbacks=%llu nonzero=%llu samples=%llu peak=%.6f errors=%u\n",atomic_load(&Callbacks),atomic_load(&NonzeroCallbacks),atomic_load(&Samples),atomic_exchange(&PeakMillionths,0)/1000000.0,atomic_load(&RenderErrors));});
    dispatch_resume(Meter);
}
