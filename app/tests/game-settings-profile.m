#import "../GameSettingsProfile.h"
#include <assert.h>
#include <stdio.h>

int main(void){@autoreleasepool{
    NSDictionary *profile=@{@"height":@720,@"fpsLimit":@60};
    StrayGameLaunchSettings s=StrayResolveGameLaunchSettings(profile,@{@"ResolutionSizeY":@"900",@"FrameRateLimit":@"45.000000"});
    assert(s.height==900 && s.fps==45);
    for(NSString *height in @[@"720",@"900",@"1080"]){
        for(NSString *fps in @[@"30.000000",@"40.000000",@"45.000000",@"50.000000",@"60.000000"]){
            s=StrayResolveGameLaunchSettings(profile,@{@"ResolutionSizeY":height,@"FrameRateLimit":fps});
            assert(s.height==(NSUInteger)height.integerValue && s.fps==(NSUInteger)fps.integerValue);
        }
    }
    // The user's v18 saved 900p file omits the default 60 FPS value.
    s=StrayResolveGameLaunchSettings(profile,@{@"ResolutionSizeY":@"900"});assert(s.height==900 && s.fps==60);
    s=StrayResolveGameLaunchSettings(@{@"height":@720,@"fpsLimit":@50,@"resolutionFromGameSettings":@NO},@{@"ResolutionSizeY":@"900",@"FrameRateLimit":@"45.000000"});
    assert(s.height==720 && s.fps==50);
    s=StrayResolveGameLaunchSettings(nil,nil);assert(s.height==720 && s.fps==60);
    for(id bad in @[@"",@"900oops",@"NaN",@"inf",@"-900",@"900.5",@(-900),NSNull.null,@[],@{}]){
        assert(StraySettingsInteger(bad)==0);
        s=StrayResolveGameLaunchSettings(profile,@{@"ResolutionSizeY":bad,@"FrameRateLimit":bad});assert(s.height==720 && s.fps==60);
    }
    s=StrayResolveGameLaunchSettings(@{@"height":@"900",@"fpsLimit":@"50.000000"},@{});assert(s.height==900 && s.fps==50);
    puts("game settings: saved INI strings, all presets, omitted defaults, explicit profile and malformed values passed");
}}
