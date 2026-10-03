#pragma once
#include <stdbool.h>

typedef struct { bool limited; double coolSince; } StrayThermalFramePolicy;
// The game's saved limit remains the user's choice. A temporary thermal cap
// requires 30 continuous seconds below Serious before returning to that limit.
static inline float StrayThermalFrameLimit(StrayThermalFramePolicy *policy,int thermal,float requested,double now){
    if(!(requested>=30 && requested<=60))requested=60;
    if(thermal>=2){policy->limited=true;policy->coolSince=0;}
    else if(policy->limited){
        if(policy->coolSince==0)policy->coolSince=now;
        if(now-policy->coolSince>=30){policy->limited=false;policy->coolSince=0;}
    }
    return policy->limited && requested>30?30:requested;
}
