#pragma once
#import <Foundation/Foundation.h>
#include <math.h>

typedef struct { NSUInteger height; NSUInteger fps; } StrayGameLaunchSettings;

// INI values are NSStrings; plist values may be NSNumbers. Validate before
// converting either type so malformed settings cannot send an invalid selector.
static inline NSUInteger StraySettingsInteger(id value){
    double number=0;
    if([value isKindOfClass:NSString.class]){
        NSScanner *scanner=[NSScanner scannerWithString:value];
        if(![scanner scanDouble:&number] || !scanner.isAtEnd)return 0;
    }else if([value isKindOfClass:NSNumber.class])number=[value doubleValue];
    else return 0;
    if(!isfinite(number) || number<=0 || number>4096 || floor(number)!=number)return 0;
    return (NSUInteger)number;
}
static inline BOOL StraySettingsHeightValid(NSUInteger height){return height==720 || height==900 || height==1080;}
static inline BOOL StraySettingsFPSValid(NSUInteger fps){return fps==30 || fps==40 || fps==45 || fps==50 || fps==60;}
static inline StrayGameLaunchSettings StrayResolveGameLaunchSettings(NSDictionary *profile,NSDictionary *savedGraphics){
    NSUInteger height=StraySettingsInteger(profile[@"height"]),fps=StraySettingsInteger(profile[@"fpsLimit"]);
    if(!StraySettingsHeightValid(height))height=720;
    if(!StraySettingsFPSValid(fps))fps=60;
    BOOL followGame=!profile[@"resolutionFromGameSettings"] || [profile[@"resolutionFromGameSettings"] boolValue];
    if(followGame){
        NSUInteger savedHeight=StraySettingsInteger(savedGraphics[@"ResolutionSizeY"]),savedFPS=StraySettingsInteger(savedGraphics[@"FrameRateLimit"]);
        if(StraySettingsHeightValid(savedHeight))height=savedHeight;
        if(StraySettingsFPSValid(savedFPS))fps=savedFPS;
    }
    return (StrayGameLaunchSettings){height,fps};
}
