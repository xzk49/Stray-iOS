#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <Metal/Metal.h>
#import <objc/runtime.h>
#include <pthread.h>
#include <stdatomic.h>

static pthread_mutex_t LifecycleLock=PTHREAD_MUTEX_INITIALIZER;
static pthread_cond_t LifecycleChanged=PTHREAD_COND_INITIALIZER;
static BOOL RendererActive=YES;
static void (*NativeCommit)(id,SEL);
static atomic_uint DeferredCommits,FailedCommands;
static atomic_uint LifecycleEpoch;

unsigned StrayMetalLifecycleEpoch(void){return atomic_load(&LifecycleEpoch);}

static void SetRendererActive(BOOL active){
    pthread_mutex_lock(&LifecycleLock);
    if(RendererActive!=active)atomic_fetch_add(&LifecycleEpoch,1);
    RendererActive=active;
    if(active)pthread_cond_broadcast(&LifecycleChanged);
    pthread_mutex_unlock(&LifecycleLock);
    fprintf(stderr,"STRAY_LIFECYCLE renderer_active=%d deferred=%u gpu_errors=%u\n",active,atomic_load(&DeferredCommits),atomic_load(&FailedCommands));
}
static void CommitWhenActive(id command,SEL selector){
    pthread_mutex_lock(&LifecycleLock);
    if(!RendererActive)atomic_fetch_add(&DeferredCommits,1);
    while(!RendererActive)pthread_cond_wait(&LifecycleChanged,&LifecycleLock);
    // Serialize the short native commit with lifecycle transitions. In-flight
    // foreground work may finish; no new GPU work is submitted after resigning.
    NativeCommit(command,selector);pthread_mutex_unlock(&LifecycleLock);
}
static void CommitWithLifecycle(id<MTLCommandBuffer> command,SEL selector){
    [command addCompletedHandler:^(id<MTLCommandBuffer> completed){
        if(completed.status==MTLCommandBufferStatusError){
            unsigned count=atomic_fetch_add(&FailedCommands,1)+1;
            fprintf(stderr,"STRAY_LIFECYCLE gpu_error count=%u code=%ld detail=%s\n",count,(long)completed.error.code,completed.error.description.UTF8String);
        }
    }];
    // UIKit's main thread must remain available to deliver the active callback.
    // The host pauses its MTKView before the next draw; defer any transition
    // straggler without fabricating completion or changing its error status.
    pthread_mutex_lock(&LifecycleLock);BOOL active=RendererActive;pthread_mutex_unlock(&LifecycleLock);
    if(!active && NSThread.isMainThread){dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED,0),^{CommitWhenActive(command,selector);});return;}
    CommitWhenActive(command,selector);
}
void StrayInstallMetalLifecycle(id<MTLDevice> device){
    id<MTLCommandBuffer> command=[[device newCommandQueue] commandBuffer];Class cls=object_getClass(command);
    Method method=class_getInstanceMethod(cls,@selector(commit));
    if(!method)return;
    NativeCommit=(void *)method_getImplementation(method);
    class_replaceMethod(cls,@selector(commit),(IMP)CommitWithLifecycle,method_getTypeEncoding(method));
    [NSNotificationCenter.defaultCenter addObserverForName:UIApplicationWillResignActiveNotification object:nil queue:nil usingBlock:^(NSNotification *n){SetRendererActive(NO);}];
    [NSNotificationCenter.defaultCenter addObserverForName:UIApplicationDidEnterBackgroundNotification object:nil queue:nil usingBlock:^(NSNotification *n){SetRendererActive(NO);}];
    [NSNotificationCenter.defaultCenter addObserverForName:UIApplicationWillEnterForegroundNotification object:nil queue:nil usingBlock:^(NSNotification *n){SetRendererActive(YES);}];
    [NSNotificationCenter.defaultCenter addObserverForName:UIApplicationDidBecomeActiveNotification object:nil queue:nil usingBlock:^(NSNotification *n){SetRendererActive(YES);}];
    fprintf(stderr,"STRAY_LIFECYCLE commit_gate class=%s\n",class_getName(cls));
}
