#pragma once
#include <stdbool.h>
#include <stdint.h>
#include <stddef.h>
#include <string.h>
static inline uint32_t StrayMovieHeaderU32(const uint8_t *p,size_t offset){
    return (uint32_t)p[offset]|(uint32_t)p[offset+1]<<8|(uint32_t)p[offset+2]<<16|(uint32_t)p[offset+3]<<24;
}
// Only the six audited KB2n files are candidates. Check the common container
// fields before selecting the original publisher's 1080p variant.
static inline bool StrayMovieHeadersMatch(const uint8_t *source,size_t sourceBytes,uint64_t sourceSize,const uint8_t *target,size_t targetBytes,uint64_t targetSize){
    if(sourceBytes<44 || targetBytes<44 || memcmp(source,"KB2n",4) || memcmp(target,"KB2n",4))return false;
    if((uint64_t)StrayMovieHeaderU32(source,4)+8!=sourceSize || (uint64_t)StrayMovieHeaderU32(target,4)+8!=targetSize)return false;
    if(StrayMovieHeaderU32(source,20)!=3840 || StrayMovieHeaderU32(source,24)!=2160 || StrayMovieHeaderU32(target,20)!=1920 || StrayMovieHeaderU32(target,24)!=1080)return false;
    if(!StrayMovieHeaderU32(source,8) || !StrayMovieHeaderU32(source,28) || !StrayMovieHeaderU32(source,32))return false;
    const size_t sameFields[]={8,16,28,32,36,40};
    for(size_t i=0;i<sizeof(sameFields)/sizeof(sameFields[0]);i++)if(StrayMovieHeaderU32(source,sameFields[i])!=StrayMovieHeaderU32(target,sameFields[i]))return false;
    return true;
}
