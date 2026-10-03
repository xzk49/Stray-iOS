#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>
#include "ThermalFramePolicy.h"
#include <mach-o/dyld.h>
#include <mach-o/loader.h>
#include <stdatomic.h>
#include <stdint.h>
#include <string.h>
#include <math.h>
#include <stdio.h>

// File-triggered A/B tests and optional thermal pacing against Stray 1.6's
// audited console ABI. Thermal pacing changes only the live frame limit.
static atomic_bool Busy;
extern void StrayStopGameLibraryCapture(void);
extern void StrayResetPerformanceTiming(void);
static double ReadCell(void *cell,BOOL isFloat,BOOL isBool){
    if(isFloat)return *(float *)cell;
    if(isBool)return *(uint8_t *)cell;
    return *(int *)cell;
}
static BOOL ResolveConsole(uintptr_t *slide,void **manager){
    const uint8_t expected[16]={0xb2,0x3c,0xfb,0xe6,0x80,0xd4,0x32,0xaa,0x96,0x75,0x5f,0x9a,0x5e,0xd4,0x53,0xde};
    for(uint32_t i=0;i<_dyld_image_count();i++){
        const char *name=_dyld_get_image_name(i);
        if(!name || !strstr(name,"/StrayGuest.dylib"))continue;
        const struct mach_header_64 *header=(const void *)_dyld_get_image_header(i);
        if(header->magic!=MH_MAGIC_64)return NO;
        const struct load_command *command=(const void *)(header+1);BOOL match=NO;
        for(uint32_t j=0;j<header->ncmds;j++){
            if(command->cmd==LC_UUID)match=!memcmp(((const struct uuid_command *)command)->uuid,expected,16);
            command=(const void *)((const char *)command+command->cmdsize);
        }
        if(!match)return NO;
        uintptr_t s=(uintptr_t)_dyld_get_image_vmaddr_slide(i);
        if(*(const uint32_t *)(s+0x101294a7cULL)!=0xa9be4ff4 ||
           *(const uint32_t *)(s+0x101294a80ULL)!=0xa9017bfd ||
           *(const uint32_t *)(s+0x103463704ULL)!=0xd10143ff ||
           *(const uint32_t *)(s+0x103463708ULL)!=0x6d0223e9 ||
           *(const uint32_t *)(s+0x1034637b4ULL)!=0xd10143ff ||
           *(const uint32_t *)(s+0x1034637b8ULL)!=0xa90257f6)return NO;
        *slide=s;*manager=*(void **)(s+0x105397c58ULL);return *manager!=NULL;
    }
    return NO;
}

static void PropagateFloat(void *manager,uintptr_t slide,void *renderCell,float value){
    void *propagation=*(void **)((uint8_t *)manager+0xc0);
    if(!propagation)return;
    uintptr_t *pv=*(uintptr_t **)propagation;
    if(pv[0]==slide+0x101a93204ULL && pv[1]==slide+0x101a932c4ULL && pv[2]==slide+0x101a9338cULL)
        ((void (*)(void *,void *,float))pv[1])(propagation,renderCell,value);
}

void StrayProcessThermalPacing(unsigned frame){
    static atomic_bool pending;
    static StrayThermalFramePolicy policy;
    static float desiredFPS,appliedFPS,lastSavedFPS,lastRenderFPS;
    static int lastThermal=-1;
    static BOOL configured,enabled;
    if(frame<600 || atomic_exchange(&pending,true))return;
    dispatch_async(dispatch_get_main_queue(),^{@autoreleasepool{
        if(!configured){NSDictionary *profile=[NSDictionary dictionaryWithContentsOfFile:[NSHomeDirectory() stringByAppendingPathComponent:@"Documents/StrayRenderProfile.plist"]];enabled=!profile[@"thermalPacing"] || [profile[@"thermalPacing"] boolValue];configured=YES;}
        if(!enabled || UIApplication.sharedApplication.applicationState!=UIApplicationStateActive){atomic_store(&pending,false);return;}
        uintptr_t slide;void *manager;
        if(!ResolveConsole(&slide,&manager)){atomic_store(&pending,false);return;}
        const uint16_t key[]={'t','.','M','a','x','F','P','S',0};
        void *variable=((void *(*)(void *,const uint16_t *,BOOL))(slide+0x101294a7cULL))(manager,key,NO);
        if(!variable){atomic_store(&pending,false);return;}
        uintptr_t getter=(*(uintptr_t **)variable)[0xa0/8];BOOL reference=getter==slide+0x1012a2ef0ULL;
        if(!reference && getter!=slide+0x101293014ULL){atomic_store(&pending,false);return;}
        float *gameCell=(void *)((uint8_t *)variable+(reference?0x50:0x44));
        float *renderCell=reference?*(void **)((uint8_t *)variable+0x48):(void *)((uint8_t *)variable+0x48);
        if(!renderCell){atomic_store(&pending,false);return;}
        float before=*gameCell;
        if(!desiredFPS || fabsf(before-appliedFPS)>.01f)desiredFPS=before;
        NSString *settings=[NSHomeDirectory() stringByAppendingPathComponent:@"Library/Preferences/Stray/MacNoEditor/GameUserSettings.ini"];
        NSString *ini=[NSString stringWithContentsOfFile:settings encoding:NSUTF8StringEncoding error:nil];float savedFPS=0;
        for(NSString *line in [ini componentsSeparatedByCharactersInSet:NSCharacterSet.newlineCharacterSet])if([line hasPrefix:@"FrameRateLimit="])savedFPS=[[line substringFromIndex:15] floatValue];
        if(savedFPS>=30 && savedFPS<=60){if(lastSavedFPS && savedFPS!=lastSavedFPS)desiredFPS=savedFPS;lastSavedFPS=savedFPS;}
        int thermal=(int)NSProcessInfo.processInfo.thermalState;
        float effective=StrayThermalFrameLimit(&policy,thermal,desiredFPS,CACurrentMediaTime());
        BOOL changed=thermal!=lastThermal || fabsf(effective-appliedFPS)>.01f || fabsf(*renderCell-lastRenderFPS)>.01f;
        if(fabsf(before-effective)>.01f){
            ((void (*)(void *,float))(slide+0x103463704ULL))(variable,effective);PropagateFloat(manager,slide,renderCell,*gameCell);
        }
        appliedFPS=*gameCell;
        if(changed){
            NSDictionary *report=@{@"frame":@(frame),@"thermalState":@(thermal),@"requestedFPS":@(desiredFPS),@"temporaryLimit":@(policy.limited),@"gameFPS":@(*gameCell),@"renderFPS":@(*renderCell)};
            [[NSJSONSerialization dataWithJSONObject:report options:NSJSONWritingPrettyPrinted error:nil] writeToFile:[NSHomeDirectory() stringByAppendingPathComponent:@"Documents/StrayThermalPacing.json"] atomically:YES];
            fprintf(stderr,"STRAY_THERMAL_PACING frame=%u state=%d requested=%.0f effective=%.0f render=%.0f limited=%d\n",frame,thermal,desiredFPS,*gameCell,*renderCell,policy.limited);
        }
        lastThermal=thermal;lastRenderFPS=*renderCell;atomic_store(&pending,false);
    }});
}

void StrayProcessRenderTestRequest(unsigned frame){
    if(frame<600 || atomic_load(&Busy))return;
    NSString *documents=[NSHomeDirectory() stringByAppendingPathComponent:@"Documents"];
    NSString *path=[documents stringByAppendingPathComponent:@"StrayRenderTest.plist"];
    if(![NSFileManager.defaultManager fileExistsAtPath:path])return;
    NSDictionary *request=[NSDictionary dictionaryWithContentsOfFile:path];
    if(atomic_exchange(&Busy,true))return;
    [NSFileManager.defaultManager removeItemAtPath:path error:nil];
    // Run outside the RHI's nextDrawable stack. UIKit's main thread differs
    // from UE's game thread, so native Set alone does not propagate the value.
    dispatch_async(dispatch_get_main_queue(),^{@autoreleasepool{
        if([request[@"stopShaderCapture"] boolValue])StrayStopGameLibraryCapture();
        if([request[@"resetPerformance"] boolValue])StrayResetPerformanceTiming();
        NSDictionary *limits=@{@"t.MaxFPS":@[@30,@60],@"r.ScreenPercentage":@[@50,@100],@"r.MotionBlurQuality":@[@0,@4],
            @"r.DepthOfFieldQuality":@[@0,@4],@"r.SSS.Scale":@[@0,@2],
            @"r.SSS.HalfRes":@[@0,@1],@"r.SSS.Burley.Quality":@[@0,@1],
            @"r.SSS.Checkerboard":@[@0,@2],@"r.SSS.Quality":@[@(-1),@1],
            @"r.SSS.Burley.SubmitCommandsBeforeSetup":@[@0,@1],@"r.PostProcessAAQuality":@[@0,@6],
            @"r.SceneColorFormat":@[@0,@5],@"r.SSR.Quality":@[@0,@4],
            @"r.TiledDeferredShading":@[@0,@1],@"r.TranslucencyLightingVolumeDim":@[@16,@64],
            @"r.BloomQuality":@[@0,@5],@"r.EyeAdaptationQuality":@[@0,@2],
            @"r.AmbientOcclusionLevels":@[@(-1),@3],@"r.ShadowQuality":@[@0,@5],
            @"r.ContactShadows":@[@0,@1],@"r.Shadow.PerObject":@[@0,@1],
            @"r.Shadow.TranslucentPerObject":@[@0,@1],
            @"r.Streaming.MipBias":@[@0,@4],@"r.Streaming.PoolSize":@[@512,@2048],
            @"r.Streaming.MaxTempMemoryAllowed":@[@32,@128],@"r.MaxAnisotropy":@[@1,@16],
            @"r.Streaming.FramesForFullUpdate":@[@1,@10],
            @"r.Streaming.FullyLoadUsedTextures":@[@0,@1],
            @"r.Streaming.UseFixedPoolSize":@[@0,@1],
            @"r.Streaming.LimitPoolSizeToVRAM":@[@0,@1],
            @"r.RHICmdBypass":@[@0,@1],@"r.RHICmdUseParallelAlgorithms":@[@0,@1],
            @"r.RHICmdUseDeferredContexts":@[@0,@1],
            @"s.AsyncLoadingThreadEnabled":@[@0,@1],@"s.AsyncLoadingTimeLimit":@[@1,@20],
            @"s.LevelStreamingActorsUpdateTimeLimit":@[@1,@10],
            @"r.VolumetricFog":@[@0,@1]};
        NSDictionary *variables=request[@"variables"];
        NSMutableDictionary *results=[NSMutableDictionary new];
        uintptr_t slide=0;void *manager=NULL;BOOL resolved=ResolveConsole(&slide,&manager);
        if(resolved && [variables isKindOfClass:NSDictionary.class]){
            for(NSString *name in [variables.allKeys sortedArrayUsingSelector:@selector(compare:)]){
                NSArray *range=limits[name];id value=variables[name];
                if(!range || name.length>=128)continue;
                BOOL isFloat=[@[@"t.MaxFPS",@"r.ScreenPercentage",@"r.SSS.Scale",@"r.Streaming.MipBias",@"s.AsyncLoadingTimeLimit",
                    @"s.LevelStreamingActorsUpdateTimeLimit"] containsObject:name];
                BOOL query=[value isKindOfClass:NSString.class] && [value isEqualToString:@"query"];
                if(!query && (![value isKindOfClass:NSNumber.class] || !isfinite([value doubleValue]) ||
                    [value doubleValue]<[range[0] doubleValue] || [value doubleValue]>[range[1] doubleValue] ||
                    (!isFloat && [value doubleValue]!=[value intValue])))continue;
                uint16_t key[128]={0};[name getCharacters:key range:NSMakeRange(0,name.length)];
                fprintf(stderr,"STRAY_RENDER_TEST find frame=%u name=%s\n",frame,name.UTF8String);
                void *variable=((void *(*)(void *,const uint16_t *,BOOL))(slide+0x101294a7cULL))(manager,key,NO);
                if(!variable){results[name]=@{@"error":@"not_found"};continue;}
                uintptr_t *vtable=*(uintptr_t **)variable;
                // GetFlags, GetInt and GetFloat offsets were checked against
                // both native FConsoleVariable<int> and <float> implementations.
                uint32_t flags=((uint32_t (*)(void *))vtable[0x20/8])(variable);
                uintptr_t getter=vtable[(isFloat?0xa0:0x98)/8];
                BOOL isReference=isFloat?getter==slide+0x1012a2ef0ULL:
                    (getter==slide+0x1012a2bc4ULL || getter==slide+0x1012a2d4cULL);
                BOOL isBool=!isFloat && (getter==slide+0x101292b98ULL || getter==slide+0x1012a2bc4ULL);
                if(isBool && !query && [value intValue]!=0 && [value intValue]!=1){results[name]=@{@"error":@"invalid_boolean"};continue;}
                uintptr_t expectedGetter=slide+(isReference?(isFloat?0x1012a2ef0ULL:(isBool?0x1012a2bc4ULL:0x1012a2d4cULL)):
                    (isFloat?0x101293014ULL:(isBool?0x101292b98ULL:0x101292decULL)));
                if(vtable[(isFloat?0xa0:0x98)/8]!=expectedGetter){results[name]=@{@"error":@"unexpected_storage_type"};continue;}
                void *gameCell=(uint8_t *)variable+(isReference?0x50:(isBool?0x41:0x44));
                void *renderCell=isReference?*(void **)((uint8_t *)variable+0x48):
                    (uint8_t *)variable+(isBool?0x42:0x48);
                if(!renderCell){results[name]=@{@"error":@"missing_render_storage"};continue;}
                double gameBefore=ReadCell(gameCell,isFloat,isBool);
                double before=ReadCell(renderCell,isFloat,isBool);
                if(!query){
                    if(isFloat)((void (*)(void *,float))(slide+0x103463704ULL))(variable,[value floatValue]);
                    else ((void (*)(void *,int))(slide+0x1034637b4ULL))(variable,[value intValue]);
                    // OnCVarChange only forwards from UE's game thread. Use
                    // its registered propagation callback, which enqueues a
                    // normal render task from other threads (audited native
                    // FConsoleRenderThreadPropagation::OnCVarChange bodies).
                    void *propagation=*(void **)((uint8_t *)manager+0xc0);
                    if(propagation){
                        uintptr_t *pv=*(uintptr_t **)propagation;
                        if(pv[0]==slide+0x101a93204ULL && pv[1]==slide+0x101a932c4ULL && pv[2]==slide+0x101a9338cULL){
                            if(isFloat)((void (*)(void *,void *,float))pv[1])(propagation,renderCell,*(float *)gameCell);
                            else if(isBool)((void (*)(void *,void *,BOOL))pv[2])(propagation,renderCell,*(uint8_t *)gameCell);
                            else ((void (*)(void *,void *,int))pv[0])(propagation,renderCell,*(int *)gameCell);
                        }
                    }
                }
                double after=ReadCell(renderCell,isFloat,isBool);
                double gameAfter=ReadCell(gameCell,isFloat,isBool);
                results[name]=@{@"before":@(before),@"after":@(after),@"gameBefore":@(gameBefore),@"gameAfter":@(gameAfter),@"flags":@(flags),@"queryOnly":@(query)};
                fprintf(stderr,"STRAY_RENDER_TEST value name=%s before=%.6g after=%.6g flags=0x%x query=%d\n",name.UTF8String,before,after,flags,query);
            }
        }
        id<MTLDevice> device=MTLCreateSystemDefaultDevice();
        NSDictionary *report=@{@"id":request[@"id"]?:@"unknown",@"frame":@(frame),@"resolved":@(resolved),@"values":results,
            @"thermalState":@(NSProcessInfo.processInfo.thermalState),
            @"metalAllocatedBytes":@(device.currentAllocatedSize),
            @"guestTexturePoolBytes":@(resolved?*(uint64_t *)(slide+0x1053efc10ULL):0)};
        NSData *data=[NSJSONSerialization dataWithJSONObject:report options:NSJSONWritingPrettyPrinted error:nil];
        [data writeToFile:[documents stringByAppendingPathComponent:@"StrayRenderTestResult.json"] atomically:YES];
        fprintf(stderr,"STRAY_RENDER_TEST completed frame=%u resolved=%d count=%lu\n",frame,resolved,(unsigned long)results.count);
        atomic_store(&Busy,false);
    }});
}
