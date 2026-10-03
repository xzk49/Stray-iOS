#include "../ThermalFramePolicy.h"
#include <assert.h>
#include <stdio.h>
int main(void){
    StrayThermalFramePolicy p={0};
    assert(StrayThermalFrameLimit(&p,0,60,100)==60);
    assert(StrayThermalFrameLimit(&p,2,60,101)==30);
    assert(StrayThermalFrameLimit(&p,1,60,102)==30);
    assert(StrayThermalFrameLimit(&p,1,60,131.9)==30);
    assert(StrayThermalFrameLimit(&p,1,50,132)==50);
    assert(StrayThermalFrameLimit(&p,3,50,133)==30);
    assert(StrayThermalFrameLimit(&p,0,45,140)==30);
    assert(StrayThermalFrameLimit(&p,2,45,165)==30);
    assert(StrayThermalFrameLimit(&p,0,45,170)==30);
    assert(StrayThermalFrameLimit(&p,0,45,199.9)==30);
    assert(StrayThermalFrameLimit(&p,0,45,200)==45);
    assert(StrayThermalFrameLimit(&p,2,30,201)==30);
    assert(StrayThermalFrameLimit(&p,0,30,232)==30);
    assert(StrayThermalFrameLimit(&p,0,30,262)==30);
    puts("thermal policy: cap, hysteresis, reheating and changed game limit passed");
}
