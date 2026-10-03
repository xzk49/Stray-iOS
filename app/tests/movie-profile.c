#include "../MovieProfile.h"
#include <assert.h>
#include <stdio.h>

static void u32(uint8_t *p, size_t offset, uint32_t value) {
    for (int i=0;i<4;i++) p[offset+i]=(uint8_t)(value>>(i*8));
}
int main(void) {
    uint8_t a[44]={0},b[44]={0};
    memcpy(a,"KB2n",4);memcpy(b,"KB2n",4);
    u32(a,4,992);u32(b,4,492);
    u32(a,8,300);u32(b,8,300);
    u32(a,20,3840);u32(a,24,2160);u32(b,20,1920);u32(b,24,1080);
    u32(a,28,30);u32(b,28,30);u32(a,32,1);u32(b,32,1);
    assert(StrayMovieHeadersMatch(a,44,1000,b,44,500));
    assert(!StrayMovieHeadersMatch(a,43,1000,b,44,500));
    assert(!StrayMovieHeadersMatch(a,44,999,b,44,500));
    assert(!StrayMovieHeadersMatch(a,44,1000,b,44,501));
    const size_t fields[]={8,16,20,24,28,32,36,40};
    for (size_t i=0;i<sizeof(fields)/sizeof(fields[0]);i++) {
        b[fields[i]]^=1;
        assert(!StrayMovieHeadersMatch(a,44,1000,b,44,500));
        b[fields[i]]^=1;
    }
    b[0]='x';assert(!StrayMovieHeadersMatch(a,44,1000,b,44,500));
    puts("movie headers: size, resolution, timing, flags, audio and truncation checks passed");
}
