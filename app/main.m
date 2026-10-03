#import <UIKit/UIKit.h>
#import <MetalKit/MetalKit.h>
#import <os/proc.h>
#import <dlfcn.h>
#import <TargetConditionals.h>
#import "AppleEventBridge.h"
#import "AppKitBridge.h"
#import "GameSettingsProfile.h"
#include <mach-o/dyld.h>
#include <mach-o/loader.h>
#include <mach-o/nlist.h>
#include <stdlib.h>
#include <string.h>
#include <stdio.h>
#include <math.h>
#include <fcntl.h>
#include <unistd.h>

static NSDictionary *ReadGuestIni(NSString *path) {
    NSString *ini=[NSString stringWithContentsOfFile:path encoding:NSUTF8StringEncoding error:nil];
    NSMutableDictionary *sections=[NSMutableDictionary new];NSString *section=@"";
    for(NSString *raw in [ini componentsSeparatedByCharactersInSet:NSCharacterSet.newlineCharacterSet]){
        NSString *line=[raw stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
        if([line hasPrefix:@"["] && [line hasSuffix:@"]"]){section=[line substringWithRange:NSMakeRange(1,line.length-2)];if(!sections[section])sections[section]=[NSMutableDictionary new];continue;}
        if([line hasPrefix:@";"] || [line hasPrefix:@"#"])continue;
        NSRange equal=[line rangeOfString:@"="];
        if(equal.location!=NSNotFound && section.length)sections[section][[line substringToIndex:equal.location]]=[line substringFromIndex:equal.location+1];
    }
    return sections;
}

static BOOL WriteGuestIni(NSString *path, NSString *backup, NSDictionary *sections) {
    NSString *old=[NSString stringWithContentsOfFile:path encoding:NSUTF8StringEncoding error:nil]?:@"";
    if(old.length && ![NSFileManager.defaultManager fileExistsAtPath:backup])
        [old writeToFile:backup atomically:YES encoding:NSUTF8StringEncoding error:nil];
    NSMutableDictionary *remaining=[NSMutableDictionary new];
    for(NSString *name in sections)remaining[name]=[sections[name] mutableCopy];
    NSMutableString *updated=[NSMutableString new];NSString *section=@"";
    for(NSString *line in [old componentsSeparatedByCharactersInSet:NSCharacterSet.newlineCharacterSet]){
        if([line hasPrefix:@"["] && [line hasSuffix:@"]"]){
            for(NSString *key in [remaining[section] allKeys])[updated appendFormat:@"%@=%@\n",key,remaining[section][key]];
            [remaining[section] removeAllObjects];
            section=[line substringWithRange:NSMakeRange(1,line.length-2)];
        }
        NSRange equal=[line rangeOfString:@"="];
        NSString *key=equal.location!=NSNotFound?[line substringToIndex:equal.location]:nil;
        NSString *replacement=sections[section][key?:@""];
        if(replacement){[updated appendFormat:@"%@=%@\n",key,replacement];[remaining[section] removeObjectForKey:key];}
        else [updated appendFormat:@"%@\n",line];
    }
    for(NSString *name in remaining)if([remaining[name] count]){
        [updated appendFormat:@"\n[%@]\n",name];
        for(NSString *key in remaining[name])[updated appendFormat:@"%@=%@\n",key,remaining[name][key]];
    }
    NSError *error=nil;
    BOOL saved=[NSFileManager.defaultManager createDirectoryAtPath:path.stringByDeletingLastPathComponent withIntermediateDirectories:YES attributes:nil error:&error] &&
               [updated writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:&error];
    fprintf(stderr,"STRAY_CONFIG file=%s saved=%d error=%s\n",path.lastPathComponent.UTF8String,saved,error.description.UTF8String?:"none");
    return saved;
}

@interface StrayQuitReceiver : NSObject
@property(nonatomic) NSUInteger callCount;
@property(nonatomic) BOOL mainThread;
@property(nonatomic) BOOL nonNilEventAndReply;
- (void)handleQuitEvent:(id)event withReplyEvent:(id)reply;
@end
@implementation StrayQuitReceiver
- (void)handleQuitEvent:(id)event withReplyEvent:(id)reply {
    self.callCount++;
    self.mainThread = NSThread.isMainThread;
    self.nonNilEventAndReply = event != nil && reply != nil;
}
@end

@interface StrayProbe : UIViewController <MTKViewDelegate>
@property(nonatomic, strong) MTKView *metalView;
@property(nonatomic, strong) UILabel *status;
@property(nonatomic, strong) id<MTLCommandQueue> queue;
@property(nonatomic, strong) id<MTLRenderPipelineState> pipeline;
@property(nonatomic, strong) NSMutableDictionary *report;
@property(nonatomic) BOOL firstFrameSubmitted;
@property(nonatomic, strong) NSMutableArray<NSValue *> *guestHandles;
@end

@implementation StrayProbe
- (void)launchGuestGame:(NSString *)path {
    if(![[NSBundle.mainBundle objectForInfoDictionaryKey:@"StrayLaunchGame"] boolValue])return;
    NSString *relative=[NSBundle.mainBundle objectForInfoDictionaryKey:@"StrayGameRelativeRoot"];
    NSString *root=relative.length?[NSBundle.mainBundle.bundlePath stringByAppendingPathComponent:relative]:[NSBundle.mainBundle objectForInfoDictionaryKey:@"StrayGameRoot"];
    NSString *pakDirectory=[root stringByAppendingPathComponent:@"Contents/UE4/Hk_project/Content/Paks"];
    NSArray *paks=[NSFileManager.defaultManager contentsOfDirectoryAtPath:pakDirectory error:nil];
    if(!root || !paks.count){[self record:@"error" value:@"Game resources are not readable"];return;}
    self.report[@"game_resource_root"]=root;self.report[@"game_resources_external"]=@(!relative.length);self.report[@"game_bundled"]=@(relative.length>0);
    NSData *image=[NSData dataWithContentsOfFile:path options:NSDataReadingMappedIfSafe error:nil];
    if(image.length<sizeof(struct mach_header_64)){[self record:@"error" value:@"Main image header unavailable"];return;}
    const struct mach_header_64 *header=image.bytes;
    if(header->magic!=MH_MAGIC_64 || header->cputype!=CPU_TYPE_ARM64){[self record:@"error" value:@"Unexpected main architecture"];return;}
    const struct symtab_command *symbols=NULL;uint64_t textStart=0,textEnd=0;
    const uint8_t *cursor=image.bytes;cursor+=sizeof(*header);
    for(uint32_t i=0;i<header->ncmds;i++){
        if(cursor+sizeof(struct load_command)>(const uint8_t *)image.bytes+image.length)break;
        const struct load_command *command=(const void *)cursor;
        if(command->cmdsize<sizeof(*command) || cursor+command->cmdsize>(const uint8_t *)image.bytes+image.length)break;
        if(command->cmd==LC_SYMTAB)symbols=(const void *)command;
        if(command->cmd==LC_SEGMENT_64){const struct segment_command_64 *segment=(const void *)command;
            const struct section_64 *sections=(const void *)(segment+1);for(uint32_t j=0;j<segment->nsects;j++)if(!strncmp(sections[j].sectname,"__text",16)){textStart=sections[j].addr;textEnd=textStart+sections[j].size;}}
        cursor+=command->cmdsize;
    }
    uint64_t entry=0;
    if(symbols && (uint64_t)symbols->symoff+symbols->nsyms*sizeof(struct nlist_64)<=image.length && (uint64_t)symbols->stroff+symbols->strsize<=image.length){
        const struct nlist_64 *table=(const void *)((const uint8_t *)image.bytes+symbols->symoff);const char *strings=(const void *)((const uint8_t *)image.bytes+symbols->stroff);
        for(uint32_t i=0;i<symbols->nsyms;i++){uint32_t offset=table[i].n_un.n_strx;if(offset>=symbols->strsize)continue;
            const char *name=strings+offset;if(!memchr(name,0,symbols->strsize-offset))continue;
            if(!strcmp(name,"_main") && (table[i].n_type&N_TYPE)==N_SECT){entry=table[i].n_value;break;}}
    }
    if(entry<textStart || entry>=textEnd){[self record:@"error" value:@"Audited _main symbol is not inside executable instructions"];return;}
    intptr_t slide=0;BOOL found=NO;
    for(uint32_t i=0;i<_dyld_image_count();i++){const char *name=_dyld_get_image_name(i);if(name && [@(name).lastPathComponent isEqualToString:@"StrayGuest.dylib"]){slide=_dyld_get_image_vmaddr_slide(i);found=YES;break;}}
    if(!found){[self record:@"error" value:@"Loaded guest image missing from dyld"];return;}
    int (*guestMain)(int,char **)=(void *)(entry+slide);
    NSString *log=[NSHomeDirectory() stringByAppendingPathComponent:@"Documents/Stray.log"];
    NSDictionary *profile=[NSDictionary dictionaryWithContentsOfFile:[NSHomeDirectory() stringByAppendingPathComponent:@"Documents/StrayRenderProfile.plist"]];
    NSString *settings=[NSHomeDirectory() stringByAppendingPathComponent:@"Library/Preferences/Stray/MacNoEditor/GameUserSettings.ini"];
    NSDictionary *savedSections=ReadGuestIni(settings);
    NSDictionary *savedGraphics=savedSections[@"/Script/Hk_project.HKGameUserSettings"];
    BOOL followGameSettings=!profile[@"resolutionFromGameSettings"] || [profile[@"resolutionFromGameSettings"] boolValue];
    StrayGameLaunchSettings launchSettings=StrayResolveGameLaunchSettings(profile,savedGraphics);
    NSUInteger height=launchSettings.height,fps=launchSettings.fps;
    NSUInteger width=height==1080?1920:(height==900?1600:1280);
    uint64_t availableMemory=os_proc_available_memory();
    BOOL expandedMemory=availableMemory>5ULL*1024*1024*1024;
    NSUInteger texturePool=[profile[@"texturePoolMB"] unsignedIntegerValue];
    if(texturePool!=512 && texturePool!=768 && texturePool!=1024 && texturePool!=1536 && texturePool!=2048)
        texturePool=expandedMemory?2048:512;
    if(!expandedMemory && texturePool>512)texturePool=512;
    // Keep game preferences and the launch request consistent. Windowed mode
    // avoids replacing the requested render size with iOS logical screen points.
    NSString *backup=[NSHomeDirectory() stringByAppendingPathComponent:@"Documents/GameUserSettings-before-mobile-profile.ini"];
    NSDictionary *defaults=@{
      @"/Script/Hk_project.HKGameUserSettings":@{@"ScreenPercentage":@"100",@"SteamDeckScreenPercentage":@"100",@"ScalingSolution":@"BuiltIn",@"bUseDynamicResolution":@"False",@"ResolutionSizeX":@(width).stringValue,@"ResolutionSizeY":@(height).stringValue,@"LastUserConfirmedResolutionSizeX":@(width).stringValue,@"LastUserConfirmedResolutionSizeY":@(height).stringValue,@"FullscreenMode":@"2",@"LastConfirmedFullscreenMode":@"2",@"PreferredFullscreenMode":@"2",@"FrameRateLimit":[NSString stringWithFormat:@"%lu.000000",(unsigned long)fps],@"bUseVSync":@"False"},
      @"ScalabilityGroups":@{@"sg.ResolutionQuality":@"100",@"sg.ShadowQuality":@"1",@"sg.EffectsQuality":@"1",@"sg.PostProcessQuality":@"1",@"sg.TextureQuality":@"1",@"sg.FoliageQuality":@"2",@"sg.ViewDistanceQuality":@"3",@"sg.ShadingQuality":@"2"}};
    NSMutableDictionary *sections=[NSMutableDictionary new];
    NSSet *required=[NSSet setWithArray:@[@"ResolutionSizeX",@"ResolutionSizeY",@"LastUserConfirmedResolutionSizeX",@"LastUserConfirmedResolutionSizeY",@"FullscreenMode",@"LastConfirmedFullscreenMode",@"PreferredFullscreenMode",@"FrameRateLimit"]];
    for(NSString *sectionName in defaults){
        NSMutableDictionary *values=[defaults[sectionName] mutableCopy];
        if(followGameSettings)for(NSString *key in values.allKeys){NSString *saved=savedSections[sectionName][key];if(saved.length && ![required containsObject:key])values[key]=saved;}
        sections[sectionName]=values;
    }
    double screenPercentage=[sections[@"/Script/Hk_project.HKGameUserSettings"][@"ScreenPercentage"] doubleValue];
    if(!isfinite(screenPercentage) || screenPercentage<50 || screenPercentage>100)screenPercentage=100;
    sections[@"/Script/Hk_project.HKGameUserSettings"][@"ScreenPercentage"]=[NSString stringWithFormat:@"%.2f",screenPercentage];
    if(!WriteGuestIni(settings,backup,sections)){[self record:@"error" value:@"Game settings could not be saved"];return;}
    // Mac RHI counts other GPU allocations against this pool. A native A/B
    // confirmed that UseFixedPoolSize=1 leaves GTexturePoolSize unchanged when
    // the console PoolSize changes; allow the engine's bounded budget update.
    NSString *engine=[settings.stringByDeletingLastPathComponent stringByAppendingPathComponent:@"Engine.ini"];
    NSDictionary *memorySettings=@{@"r.TextureStreaming":@"1",@"r.Streaming.PoolSize":@(texturePool).stringValue,
        @"r.Streaming.UseFixedPoolSize":@"0",@"r.Streaming.MaxTempMemoryAllowed":@"64",
        @"r.Streaming.MipBias":@"0",@"r.Streaming.UsePerTextureBias":@"1",
        @"r.Streaming.MaxEffectiveScreenSize":@(width).stringValue};
    if(!WriteGuestIni(engine,[NSHomeDirectory() stringByAppendingPathComponent:@"Documents/Engine-before-mobile-memory.ini"],@{@"SystemSettings":memorySettings})){
        [self record:@"error" value:@"Memory settings could not be saved"];return;
    }
    NSMutableArray *arguments=[@[[root stringByAppendingPathComponent:@"Contents/MacOS/Stray-Mac-Shipping"],@"-NoSplash",@"-Windowed",@"-ForceRes",[NSString stringWithFormat:@"-ResX=%lu",(unsigned long)width],[NSString stringWithFormat:@"-ResY=%lu",(unsigned long)height],@"-AudioMixer",[NSString stringWithFormat:@"-ExecCmds=r.ScreenPercentage %.2f,r.MotionBlurQuality 0,t.MaxFPS %lu",screenPercentage,(unsigned long)fps],@"-stdout",[@"-abslog=" stringByAppendingString:log]] mutableCopy];
    fprintf(stderr,"STRAY_RENDER_PROFILE size=%lux%lu screen_percentage=%.2f fps_limit=%lu from_game_settings=%d audio=enabled\n",(unsigned long)width,(unsigned long)height,screenPercentage,(unsigned long)fps,followGameSettings);
    fprintf(stderr,"STRAY_MEMORY_PROFILE texture_pool_mb=%lu temp_texture_mb=64 mip_bias=0 per_texture_bias=1 expanded_allowance=%d\n",(unsigned long)texturePool,expandedMemory);
    fprintf(stderr,"STRAY_MEMORY_AVAILABLE physical_mb=%.1f available_mb=%.1f\n",NSProcessInfo.processInfo.physicalMemory/1048576.0,availableMemory/1048576.0);
    NSArray *extra=[NSBundle.mainBundle objectForInfoDictionaryKey:@"StrayExtraArguments"];
    if([extra isKindOfClass:NSArray.class])for(id arg in extra)if([arg isKindOfClass:NSString.class])[arguments addObject:arg];
    self.report[@"game_arguments"]=arguments;self.report[@"game_entry_symbol"]=@"_main";
    self.report[@"game_entry_address_from_symbol_table"]=[NSString stringWithFormat:@"0x%llx",entry];
    [self record:@"game_launch_stage" value:@"Starting original game main on bootstrap thread"];
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED,0),^{@autoreleasepool{
        int count=(int)arguments.count;char **argv=calloc(count+1,sizeof(char *));for(int i=0;i<count;i++)argv[i]=strdup([arguments[i] UTF8String]);
        dispatch_sync(dispatch_get_main_queue(),^{self.report[@"guest_main_stage"]=@"Original game entry running";[self record:@"game_entry_called" value:@YES];});
        int status=guestMain(count,argv);for(int i=0;i<count;i++)free(argv[i]);free(argv);
        dispatch_async(dispatch_get_main_queue(),^{self.report[@"game_exit_code"]=@(status);[self record:@"game_launch_stage" value:@"Original game main returned"];
        });
    }});
}
- (BOOL)checkAppKitBridge {
    NSString *path=[NSBundle.mainBundle.bundlePath stringByAppendingPathComponent:@"Frameworks/libStrayAppKit.dylib"];
    if(![NSFileManager.defaultManager fileExistsAtPath:path])return YES;
    [self record:@"appkit_stage" value:@"Validating UIKit window and Metal layer adapter"];
    void *handle=dlopen(path.fileSystemRepresentation,RTLD_NOW|RTLD_LOCAL);
    if(!handle){const char *message=dlerror();[self record:@"error" value:message?@(message):@"AppKit adapter rejected"];return NO;}
    [self.guestHandles addObject:[NSValue valueWithPointer:handle]];
    NSString *manifest=[NSBundle.mainBundle pathForResource:@"appkit-imports" ofType:@"json"];
    NSArray *required=manifest?[NSJSONSerialization JSONObjectWithData:[NSData dataWithContentsOfFile:manifest] options:0 error:nil]:@[];
    NSMutableArray *missing=[NSMutableArray new];for(NSString *symbol in required)if(!dlsym(handle,symbol.UTF8String))[missing addObject:symbol];
    void (*bindWindow)(UIWindow *)=dlsym(handle,"StrayAppKitBindHostWindow");
    NSDictionary *(*runtimeReport)(void)=dlsym(handle,"StrayAppKitRuntimeReport");
    BOOL windowPassed=NO,metalPassed=NO,coordinatesPassed=NO;
    if(bindWindow && missing.count==0){
        bindWindow(self.view.window);
        Class windowClass=NSClassFromString(@"NSWindow"),viewClass=NSClassFromString(@"NSView");
        NSWindow *window=[[windowClass alloc]initWithContentRect:CGRectMake(0,0,320,180) styleMask:0 backing:2 defer:NO];
        NSView *view=[[viewClass alloc]initWithFrame:CGRectMake(0,0,320,180)];
        CAMetalLayer *layer=[CAMetalLayer layer];layer.device=MTLCreateSystemDefaultDevice();layer.pixelFormat=MTLPixelFormatBGRA8Unorm;layer.drawableSize=CGSizeMake(320,180);
        view.layer=layer;view.wantsLayer=YES;window.contentView=view;[window makeKeyAndOrderFront:nil];[CATransaction flush];
        windowPassed=window.nativeWindow.isKeyWindow && view.nativeView.window==window.nativeWindow && view.layer.superlayer==view.nativeView.layer;
        CGRect original=CGRectMake(3,4,11,13),backing=[view convertRectToBacking:original],roundTrip=[view convertRectFromBacking:backing];
        coordinatesPassed=CGRectEqualToRect(original,roundTrip);
        id<CAMetalDrawable> drawable=[layer nextDrawable];
        if(drawable){MTLRenderPassDescriptor *pass=[MTLRenderPassDescriptor renderPassDescriptor];pass.colorAttachments[0].texture=drawable.texture;
            pass.colorAttachments[0].loadAction=MTLLoadActionClear;pass.colorAttachments[0].storeAction=MTLStoreActionStore;pass.colorAttachments[0].clearColor=MTLClearColorMake(0.04,0.08,0.12,1);
            id<MTLCommandBuffer> command=[[layer.device newCommandQueue] commandBuffer];id<MTLRenderCommandEncoder> encoder=[command renderCommandEncoderWithDescriptor:pass];[encoder endEncoding];[command presentDrawable:drawable];[command commit];[command waitUntilCompleted];metalPassed=command.status==MTLCommandBufferStatusCompleted;}
        [window close];[self.view.window makeKeyAndVisible];bindWindow(self.view.window);
    }
    BOOL passed=required.count>0 && missing.count==0 && windowPassed && metalPassed && coordinatesPassed;
    self.report[@"appkit_compatibility_checks"]=@{@"passed":@(passed),@"required_symbol_count":@(required.count),@"missing_symbols":missing,
        @"prototype_window_passed":@(windowPassed),@"prototype_metal_clear_frame_passed":@(metalPassed),@"backing_coordinate_round_trip":@(coordinatesPassed),
        @"runtime":runtimeReport?runtimeReport():@{}};
    [self record:@"appkit_stage" value:passed?@"AppKit prototype window and Metal presentation passed":@"AppKit adapter validation failed"];
    if(!passed)[self record:@"error" value:@"AppKit adapter validation failed"];
    return passed;
}
- (void)checkFrameworkSymbols {
    NSString *path=[NSBundle.mainBundle pathForResource:@"framework-imports" ofType:@"json"];if(!path)return;
    NSDictionary *groups=[NSJSONSerialization JSONObjectWithData:[NSData dataWithContentsOfFile:path] options:0 error:nil];
    NSMutableDictionary *results=[NSMutableDictionary new];
    for(NSString *framework in groups){NSDictionary *item=groups[framework];NSString *library=item[@"path"];
        if([library hasPrefix:@"@loader_path/"])library=[NSBundle.mainBundle.bundlePath stringByAppendingPathComponent:[@"Frameworks/" stringByAppendingString:[library substringFromIndex:13]]];
        void *handle=dlopen(library.fileSystemRepresentation,RTLD_NOW|RTLD_LOCAL);NSMutableArray *missing=[NSMutableArray new];
        const char *error=handle?NULL:dlerror();NSString *loadError=error?@(error):@"";
        NSMutableArray *weakMissing=[NSMutableArray new];
        for(NSString *symbol in item[@"symbols"]){dlerror();if(handle)dlsym(handle,symbol.UTF8String);const char *symbolError=handle?dlerror():"Library unavailable";
            if(symbolError){if([item[@"weak_symbols"] containsObject:symbol])[weakMissing addObject:symbol];else[missing addObject:symbol];}}
        if(handle)[self.guestHandles addObject:[NSValue valueWithPointer:handle]];
        results[framework]=@{@"required_count":@([item[@"symbols"] count]),@"missing_symbols":missing,@"missing_weak_symbols":weakMissing,@"load_error":loadError};
    }
    [self record:@"framework_symbol_checks" value:results];
}
- (BOOL)checkCocoaBridge {
    NSString *path = [NSBundle.mainBundle.bundlePath stringByAppendingPathComponent:@"Frameworks/libStrayCocoa.dylib"];
    if (![NSFileManager.defaultManager fileExistsAtPath:path]) return YES;
    [self record:@"cocoa_stage" value:@"Loading Foundation forwarding library"];
    dlerror();
    void *handle = dlopen(path.fileSystemRepresentation, RTLD_NOW | RTLD_LOCAL);
    if (!handle) {
        const char *message = dlerror();
        [self record:@"error" value:message ? @(message) : @"Cocoa forwarding library rejected"];
        return NO;
    }
    [self.guestHandles addObject:[NSValue valueWithPointer:handle]];
    Class (*classFromString)(NSString *) = dlsym(handle, "NSClassFromString");
    NSString *(*homeDirectory)(void) = dlsym(handle, "NSHomeDirectory");
    NSDictionary *(*capabilities)(void) = dlsym(handle, "StrayCocoaCapabilities");
    void *processClass = dlsym(handle, "OBJC_CLASS_$_NSProcessInfo");
    BOOL classPassed = classFromString && classFromString(@"NSString") == NSString.class;
    BOOL homePassed = homeDirectory && [homeDirectory() isEqualToString:NSHomeDirectory()];
    BOOL processPassed = processClass == (__bridge void *)NSProcessInfo.class;
    NSString *manifestPath = [NSBundle.mainBundle pathForResource:@"foundation-imports" ofType:@"json"];
    NSArray *requiredSymbols = manifestPath ? [NSJSONSerialization JSONObjectWithData:
        [NSData dataWithContentsOfFile:manifestPath] options:0 error:nil] : @[];
    NSMutableArray *missingSymbols = [NSMutableArray new];
    for (NSString *symbol in requiredSymbols) {
        if (!dlsym(handle, symbol.UTF8String)) [missingSymbols addObject:symbol];
    }
    BOOL (*dispatchQuit)(void) = dlsym(handle, "StrayDispatchQuitEvent");
    Class managerClass = classFromString ? classFromString(@"NSAppleEventManager") : Nil;
    BOOL quitPassed = NO;
    if (dispatchQuit && managerClass) {
        NSAppleEventManager *manager = [managerClass sharedAppleEventManager];
        StrayQuitReceiver *first = [StrayQuitReceiver new], *second = [StrayQuitReceiver new];
        [manager setEventHandler:first andSelector:@selector(handleQuitEvent:withReplyEvent:)
                  forEventClass:0x61657674 andEventID:0x71756974];
        BOOL firstDelivered = dispatchQuit();
        [manager setEventHandler:second andSelector:@selector(handleQuitEvent:withReplyEvent:)
                  forEventClass:0x61657674 andEventID:0x71756974];
        BOOL replacementDelivered = dispatchQuit();
        [manager removeEventHandlerForEventClass:0x61657674 andEventID:0x71756974];
        BOOL removed = !dispatchQuit();
        quitPassed = firstDelivered && replacementDelivered && removed && first.callCount == 1 &&
            second.callCount == 1 && first.mainThread && second.mainThread &&
            first.nonNilEventAndReply && second.nonNilEventAndReply;
    }
    BOOL forwardingPassed = classPassed && homePassed && processPassed && capabilities;
    BOOL passed = forwardingPassed && requiredSymbols.count > 0 && missingSymbols.count == 0 && quitPassed;
    self.report[@"cocoa_compatibility_checks"] = @{
        @"passed": @(passed), @"foundation_function_reexport": @(classPassed),
        @"forwarding_checks_passed": @(forwardingPassed),
        @"sandbox_home_directory": @(homePassed), @"foundation_class_reexport": @(processPassed),
        @"required_foundation_symbol_count": @(requiredSymbols.count),
        @"missing_foundation_symbols": missingSymbols,
        @"all_required_foundation_symbols_resolved": @(requiredSymbols.count > 0 && missingSymbols.count == 0),
        @"local_quit_event_registration_dispatch_and_removal": @(quitPassed),
        @"capabilities": capabilities ? capabilities() : @{}};
    [self record:@"cocoa_stage" value:passed ? @"Cocoa forwarding checks passed; AppKit is separate" : @"Cocoa forwarding checks failed"];
    if (!passed) [self record:@"error" value:@"Cocoa forwarding validation failed"];
    return passed;
}
- (BOOL)checkKeyboardBridge {
    NSString *path = [NSBundle.mainBundle.bundlePath stringByAppendingPathComponent:@"Frameworks/libStrayCoreServices.dylib"];
    if (![NSFileManager.defaultManager fileExistsAtPath:path]) return YES;
    [self record:@"keyboard_stage" value:@"Checking Carbon/CoreServices keyboard ABI"];
    void *handle = dlopen(path.fileSystemRepresentation, RTLD_NOW | RTLD_LOCAL);
    if (!handle) {
        const char *message = dlerror();
        [self record:@"error" value:message ? @(message) : @"Keyboard library rejected"];
        return NO;
    }
    [self.guestHandles addObject:[NSValue valueWithPointer:handle]];
    CFTypeRef (*copySource)(void) = dlsym(handle, "TISCopyCurrentKeyboardLayoutInputSource");
    void *(*getProperty)(CFTypeRef, CFStringRef) = dlsym(handle, "TISGetInputSourceProperty");
    const CFStringRef *layoutKey = dlsym(handle, "kTISPropertyUnicodeKeyLayoutData");
    uint8_t (*keyboardType)(void) = dlsym(handle, "LMGetKbdType");
    int32_t (*translate)(const void *, uint16_t, uint16_t, uint32_t, uint32_t, uint32_t,
                        uint32_t *, unsigned long, unsigned long *, uint16_t *) = dlsym(handle, "UCKeyTranslate");
    NSDictionary *(*capabilities)(void) = dlsym(handle, "StrayKeyboardCapabilities");
    BOOL symbolsPassed = copySource && getProperty && layoutKey && keyboardType && translate && capabilities;
    CFTypeRef source = symbolsPassed ? copySource() : NULL;
    CFDataRef layout = source ? getProperty(source, *layoutKey) : NULL;
    BOOL layoutPassed = layout && CFGetTypeID(layout) == CFDataGetTypeID() && CFDataGetLength(layout) > 0;
    NSString *referencePath = [NSBundle.mainBundle pathForResource:@"keyboard-reference" ofType:@"json"];
    NSArray *cases = referencePath ? [NSJSONSerialization JSONObjectWithData:
        [NSData dataWithContentsOfFile:referencePath] options:0 error:nil] : @[];
    NSUInteger passedCases = 0;
    if (layoutPassed) for (NSDictionary *item in cases) {
        uint16_t output[8] = {0}; uint32_t state = 0; unsigned long length = 0;
        int32_t result = translate(CFDataGetBytePtr(layout), [item[@"key"] unsignedShortValue],
            [item[@"action"] unsignedShortValue], [item[@"modifiers"] unsignedIntValue], keyboardType(),
            1, &state, 8, &length, output);
        NSArray *expected = item[@"characters"];
        BOOL equal = result == [item[@"status"] intValue] && state == 0 && length == expected.count && length <= 8;
        for (unsigned long i = 0; equal && i < length; i++) equal = output[i] == [expected[i] unsignedShortValue];
        if (equal) passedCases++;
    }
    BOOL boundaryPassed = NO, invalidPassed = NO;
    if (layoutPassed) {
        uint16_t output[2] = {0xAAAA, 0xBBBB}; uint32_t state = 0; unsigned long length = 99;
        int32_t result = translate(CFDataGetBytePtr(layout), 0, 0, 0, keyboardType(), 1, &state, 0, &length, output);
        boundaryPassed = result == -25340 && length == 0 && output[0] == 0xAAAA && output[1] == 0xBBBB;
        invalidPassed = translate(NULL, 0, 0, 0, keyboardType(), 1, &state, 2, &length, output) == -50;
    }
    if (source) CFRelease(source);
    BOOL passed = symbolsPassed && layoutPassed && cases.count > 0 && passedCases == cases.count && boundaryPassed && invalidPassed;
    self.report[@"keyboard_compatibility_checks"] = @{@"passed": @(passed),
        @"native_reference_case_count": @(cases.count), @"matching_case_count": @(passedCases),
        @"buffer_boundary": @(boundaryPassed), @"invalid_parameter": @(invalidPassed),
        @"cf_data_layout": @(layoutPassed), @"capabilities": capabilities ? capabilities() : @{}};
    [self record:@"keyboard_stage" value:passed ? @"Keyboard ABI and native reference checks passed" : @"Keyboard validation failed"];
    if (!passed) [self record:@"error" value:@"Keyboard compatibility validation failed"];
    return passed;
}
- (void)checkGuestMain {
    NSString *path = [NSBundle.mainBundle.bundlePath stringByAppendingPathComponent:@"Frameworks/StrayGuest.dylib"];
    if (![NSFileManager.defaultManager fileExistsAtPath:path]) return;
    [self record:@"guest_main_stage" value:@"Loading main image; no game entry call"];
    dlerror();
    void *handle = dlopen(path.fileSystemRepresentation, RTLD_NOW | RTLD_LOCAL);
    if (!handle) {
        const char *message = dlerror();
        self.report[@"guest_main_loaded"] = @NO;
        [self record:@"guest_main_error" value:message ? @(message) : @"Unknown dlopen error"];
        return;
    }
    [self.guestHandles addObject:[NSValue valueWithPointer:handle]];
    self.report[@"guest_main_loaded"] = @YES;
    [self record:@"guest_main_stage" value:@"Main image loaded; game entry has not been called"];
    [self launchGuestGame:path];
}
- (void)checkGuestLibraries {
    NSArray<NSString *> *names = @[@"libogg.dylib", @"libvorbis.dylib", @"libPxFoundation.dylib",
        @"libPxPvdSDK.dylib", @"libPhysX3Common.dylib", @"libPhysX3.dylib", @"libPhysX3Cooking.dylib",
        @"libApexFramework.dylib", @"libAPEX_Legacy.dylib", @"libAPEX_Clothing.dylib",
        @"libAPEX_Destructible.dylib", @"libNvCloth.dylib"];
    self.guestHandles = [NSMutableArray new];
    NSMutableArray *results = [NSMutableArray new];
    NSString *directory = [NSBundle.mainBundle.bundlePath stringByAppendingPathComponent:@"Frameworks"];
    self.report[@"guest_library_checks"] = results;
    for (NSString *name in names) {
        NSString *path = [directory stringByAppendingPathComponent:name];
        if (![NSFileManager.defaultManager fileExistsAtPath:path]) {
            [self record:@"guest_libraries" value:@"Diagnostic guest libraries not bundled"];
            return;
        }
        // dlopen runs library initializers. Save the stage before each call so
        // a device crash can be distinguished from a normal loader rejection.
        [self record:@"guest_load_stage" value:name];
        dlerror();
        void *handle = dlopen(path.fileSystemRepresentation, RTLD_NOW | RTLD_LOCAL);
        if (!handle) {
            const char *message = dlerror();
            [results addObject:@{@"library": name, @"loaded": @NO,
                @"error": message ? @(message) : @"Unknown dlopen error"}];
            [self record:@"guest_libraries" value:[NSString stringWithFormat:@"Loader stopped at %@", name]];
            return;
        }
        [self.guestHandles addObject:[NSValue valueWithPointer:handle]];
        [results addObject:@{@"library": name, @"loaded": @YES}];
    }
    [self record:@"guest_libraries" value:@"All 12 guest libraries loaded; game entry has not been called"];
    if (![self checkCocoaBridge]) return;
    if (![self checkKeyboardBridge]) return;
    if (![self checkAppKitBridge]) return;
    [self checkFrameworkSymbols];
    [self checkGuestMain];
}
- (void)record:(NSString *)key value:(id)value {
    self.report[key] = value;
    NSString *file = [NSHomeDirectory() stringByAppendingPathComponent:@"Documents/environment.json"];
    NSData *data = [NSJSONSerialization dataWithJSONObject:self.report options:NSJSONWritingPrettyPrinted error:nil];
    [data writeToFile:file atomically:YES];
    NSString *detail = [value description];
    if ([key isEqualToString:@"guest_main_error"]) {
        NSRange missing = [detail rangeOfString:@"Library not loaded: "];
        if (missing.location != NSNotFound) {
            NSString *dependency = [[detail substringFromIndex:NSMaxRange(missing)] componentsSeparatedByString:@"\n"].firstObject;
            detail = [NSString stringWithFormat:@"主程序加载失败：缺少 %@ 框架\n完整错误已写入日志", dependency.lastPathComponent];
        } else if ([detail containsString:@"cannot dlopen a main executable"]) {
            detail = @"主程序加载失败：当前加载器拒绝可执行文件\n完整错误已写入日志";
        } else {
            detail = @"主程序加载失败，完整错误已写入日志";
        }
    } else if (detail.length > 180) {
        detail = [[detail substringToIndex:180] stringByAppendingString:@"…"];
    }
    NSUInteger loaded = 0;
    for (NSDictionary *item in self.report[@"guest_library_checks"]) if ([item[@"loaded"] boolValue]) loaded++;
    NSString *metal = [self.report[@"first_frame"] isEqualToString:@"Native Metal frame completed"] ? @"通过" : @"等待结果";
    NSString *environment = TARGET_OS_SIMULATOR ? @"iOS 模拟器" : @"iPhone 真机";
    NSDictionary *cocoa = self.report[@"cocoa_compatibility_checks"];
    NSDictionary *keyboard = self.report[@"keyboard_compatibility_checks"];
    NSString *cocoaStatus = [cocoa[@"passed"] boolValue] ? @"转发通过" : @"待验证";
    NSString *keyboardStatus = [keyboard[@"passed"] boolValue] ? [NSString stringWithFormat:@"%@ / %@ 通过",
        keyboard[@"matching_case_count"], keyboard[@"native_reference_case_count"]] : @"待验证";
    NSUInteger foundationCount = [cocoa[@"required_foundation_symbol_count"] unsignedIntegerValue];
    NSUInteger missingCount = [cocoa[@"missing_foundation_symbols"] count];
    NSString *missing = foundationCount ? [NSString stringWithFormat:@"Foundation 导入：%lu / %lu 可用\n",
        (unsigned long)(foundationCount - missingCount), (unsigned long)foundationCount] : @"";
    NSString *entryStatus=[self.report[@"game_entry_called"] boolValue]?@"游戏入口已调用；菜单与场景待验证":@"尚未调用游戏入口";
    self.status.text = [NSString stringWithFormat:@"Stray 加载测试\n\n环境：%@ / iOS %@\nMetal 首帧：%@\n底层库加载：%lu / 12\nCocoa：%@\n键盘映射：%@\n%@\n%@\n\n%@", environment,
        self.report[@"ios"], metal, (unsigned long)loaded, cocoaStatus, keyboardStatus, missing, detail,entryStatus];
    if([[NSBundle.mainBundle objectForInfoDictionaryKey:@"StrayLaunchGame"] boolValue]){
        NSArray *extra=[NSBundle.mainBundle objectForInfoDictionaryKey:@"StrayExtraArguments"];
        BOOL headless=[extra containsObject:@"-NullRHI"];
        self.status.text=headless?@"Stray\n\n无渲染启动测试\n游戏画面未启用":@"Stray\n\n正在启动游戏…";
        if(self.report[@"error"] || self.report[@"guest_main_error"])
            self.status.text=[@"Stray\n\n启动失败\n" stringByAppendingString:detail];
    }
    NSLog(@"STRAY_PROBE %@ %@", key, value);
}
- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = UIColor.blackColor;
    self.report = [@{@"ios": UIDevice.currentDevice.systemVersion,
                      @"execution_environment": TARGET_OS_SIMULATOR ? @"ios-simulator" : @"ios-device",
                      @"physical_memory_bytes": @(NSProcessInfo.processInfo.physicalMemory),
                      @"available_memory_bytes_at_start": @(os_proc_available_memory()),
                      @"game_bundled": @NO, @"game_entry_called": @NO} mutableCopy];
    id<MTLDevice> device = MTLCreateSystemDefaultDevice();
    self.metalView = [[MTKView alloc] initWithFrame:self.view.bounds device:device];
    self.metalView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    self.metalView.colorPixelFormat = MTLPixelFormatBGRA8Unorm;
    self.metalView.clearColor = MTLClearColorMake(0.02, 0.04, 0.07, 1);
    self.metalView.preferredFramesPerSecond = 30;
    self.metalView.paused = YES;
    [self.view addSubview:self.metalView];
    self.status = [[UILabel alloc] initWithFrame:self.view.bounds];
    self.status.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    self.status.numberOfLines = 0;
    self.status.textAlignment = NSTextAlignmentCenter;
    self.status.textColor = UIColor.whiteColor;
    self.status.font = [UIFont systemFontOfSize:18];
    [self.view addSubview:self.status];
    if (!device) { [self record:@"error" value:@"No Metal device"]; return; }
    self.report[@"gpu"] = device.name;
    self.report[@"apple_gpu_family_7"] = @([device supportsFamily:MTLGPUFamilyApple7]);
    self.queue = [device newCommandQueue];
    NSString *source = @"#include <metal_stdlib>\nusing namespace metal;\n"
        "struct V { float4 position [[position]]; float3 color; };\n"
        "vertex V vertexMain(uint i [[vertex_id]]) {\n"
        "float2 p[3] = {float2(-0.75,-0.85),float2(0.75,-0.85),float2(0,0.15)};\n"
        "V v; v.position=float4(p[i],0,1); v.color=float3(0.15,0.55,0.7); return v; }\n"
        "fragment float4 fragmentMain(V v [[stage_in]]) { return float4(v.color,1); }\n";
    NSError *error = nil;
    id<MTLLibrary> library = [device newLibraryWithSource:source options:nil error:&error];
    if (!library) { [self record:@"error" value:error.localizedDescription ?: @"Shader compile failed"]; return; }
    MTLRenderPipelineDescriptor *descriptor = [MTLRenderPipelineDescriptor new];
    descriptor.vertexFunction = [library newFunctionWithName:@"vertexMain"];
    descriptor.fragmentFunction = [library newFunctionWithName:@"fragmentMain"];
    descriptor.colorAttachments[0].pixelFormat = self.metalView.colorPixelFormat;
    self.pipeline = [device newRenderPipelineStateWithDescriptor:descriptor error:&error];
    if (!self.pipeline || !self.queue) { [self record:@"error" value:error.localizedDescription ?: @"Pipeline or queue failed"]; return; }
    [self record:@"native_shader_pipeline" value:@"Ready; waiting for first GPU frame"];
    self.metalView.delegate = self;
    self.metalView.paused = NO;
}
- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    self.status.frame = UIEdgeInsetsInsetRect(self.view.bounds, UIEdgeInsetsMake(60, 24, 50, 24));
}
- (void)mtkView:(MTKView *)view drawableSizeWillChange:(CGSize)size {}
- (void)drawInMTKView:(MTKView *)view {
    MTLRenderPassDescriptor *pass = view.currentRenderPassDescriptor;
    id<CAMetalDrawable> drawable = view.currentDrawable;
    if (!pass || !drawable) return;
    id<MTLCommandBuffer> buffer = [self.queue commandBuffer];
    id<MTLRenderCommandEncoder> encoder = [buffer renderCommandEncoderWithDescriptor:pass];
    [encoder setRenderPipelineState:self.pipeline];
    if(![[NSBundle.mainBundle objectForInfoDictionaryKey:@"StrayLaunchGame"] boolValue])
        [encoder drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];
    [encoder endEncoding];
    [buffer presentDrawable:drawable];
    if (!self.firstFrameSubmitted) {
        self.firstFrameSubmitted = YES;
        [buffer addCompletedHandler:^(id<MTLCommandBuffer> completed) {
            dispatch_async(dispatch_get_main_queue(), ^{
                if([[NSBundle.mainBundle objectForInfoDictionaryKey:@"StrayLaunchGame"] boolValue])self.metalView.paused=YES;
                [self record:@"first_frame" value:completed.status == MTLCommandBufferStatusCompleted
                 ? @"Native Metal frame completed" : completed.error.localizedDescription ?: @"GPU command failed"];
                if (completed.status == MTLCommandBufferStatusCompleted) [self checkGuestLibraries];
            });
        }];
    }
    [buffer commit];
}
@end

@interface StrayDelegate : UIResponder <UIApplicationDelegate>
@property(nonatomic, strong) UIWindow *window;
@end
@implementation StrayDelegate
- (void)applicationWillResignActive:(UIApplication *)app {
    StrayProbe *probe=(id)self.window.rootViewController;probe.metalView.paused=YES;
}
- (void)applicationDidBecomeActive:(UIApplication *)app {
    StrayProbe *probe=(id)self.window.rootViewController;
    // The host triangle is only a startup diagnostic; the guest owns rendering.
    probe.metalView.paused=probe.firstFrameSubmitted;
}
- (BOOL)application:(UIApplication *)app didFinishLaunchingWithOptions:(NSDictionary *)options {
    // Continuous game startup/debugging needs a foreground device. This setting
    // applies only while our app is active and avoids changing user preferences.
    app.idleTimerDisabled=YES;
    NSString *log=[NSHomeDirectory() stringByAppendingPathComponent:@"Documents/StrayStartup.log"];
    int fd=open(log.fileSystemRepresentation,O_WRONLY|O_CREAT|O_APPEND,0600);
    if(fd>=0){dup2(fd,STDERR_FILENO);close(fd);setvbuf(stderr,NULL,_IONBF,0);}
    fprintf(stderr,"STRAY_STARTUP %s\n",NSDate.date.description.UTF8String);
    self.window = [[UIWindow alloc] initWithFrame:UIScreen.mainScreen.bounds];
    self.window.rootViewController = [StrayProbe new];
    [self.window makeKeyAndVisible];
    return YES;
}
@end
int main(int argc, char **argv) {
    @autoreleasepool { return UIApplicationMain(argc, argv, nil, NSStringFromClass(StrayDelegate.class)); }
}
