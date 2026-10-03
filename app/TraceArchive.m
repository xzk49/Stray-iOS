#import <Foundation/Foundation.h>
#import <CommonCrypto/CommonDigest.h>
#import <Metal/Metal.h>
#include <stdio.h>
#include <string.h>

// A host-confirmed backup request is restricted to this application's own GPU
// captures. Verify the complete local-device tar digest before removing its
// source bundle, so all removed resources remain recoverable from the host tar.
void StrayProcessTraceCleanupRequest(void){
    NSFileManager *files=NSFileManager.defaultManager;
    NSString *documents=[NSHomeDirectory() stringByAppendingPathComponent:@"Documents"];
    NSString *request=[documents stringByAppendingPathComponent:@"StrayCaptureCleanupRequest.json"];
    NSData *data=[NSData dataWithContentsOfFile:request];
    if(!data)return;
    NSDictionary *item=[NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
    if(![item isKindOfClass:NSDictionary.class])return;
    NSString *name=item[@"trace_name"],*expected=item[@"backed_up_tar_sha256"];
    if(![name isKindOfClass:NSString.class])return;
    NSRegularExpression *pattern=[NSRegularExpression regularExpressionWithPattern:@"^StrayModelDebug-[0-9]{6,10}\\.gputrace$" options:0 error:nil];
    if(![pattern firstMatchInString:name options:0 range:NSMakeRange(0,name.length)])return;
    if([item[@"discard_incomplete_diagnostic"] isEqual:@YES]){
        NSString *trace=[documents stringByAppendingPathComponent:name];
        // Only an explicit request can discard an interrupted diagnostic.
        // A complete capture must still pass the full backup digest below.
        if(MTLCaptureManager.sharedCaptureManager.isCapturing || ![files fileExistsAtPath:trace] || [files fileExistsAtPath:[trace stringByAppendingPathComponent:@"index"]]){
            fprintf(stderr,"STRAY_MODEL_CAPTURE incomplete_cleanup skipped=active_absent_or_complete\n");
            [files removeItemAtPath:request error:nil];return;
        }
        if(![files removeItemAtPath:request error:nil])return;
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY,0),^{ @autoreleasepool {
            NSError *error=nil;BOOL removed=[files removeItemAtPath:trace error:&error];
            fprintf(stderr,"STRAY_MODEL_CAPTURE incomplete_cleanup file=%s removed=%d error=%s\n",name.UTF8String,removed,error.description.UTF8String?:"none");
        }});return;
    }
    if(![expected isKindOfClass:NSString.class] || expected.length!=64)return;
    if(![files removeItemAtPath:request error:nil])return;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY,0),^{ @autoreleasepool {
        NSString *trace=[documents stringByAppendingPathComponent:name],*tar=[trace stringByAppendingString:@".tar"];
        NSFileHandle *input=[NSFileHandle fileHandleForReadingAtPath:tar];
        if(!input){fprintf(stderr,"STRAY_MODEL_CAPTURE cleanup skipped=no_archive\n");return;}
        CC_SHA256_CTX context;CC_SHA256_Init(&context);
        @try {
            for(;;){@autoreleasepool{
                NSData *part=[input readDataOfLength:1024*1024];
                if(!part.length)break;
                CC_SHA256_Update(&context,part.bytes,(CC_LONG)part.length);
            }}
        }@catch(NSException *exception){[input closeFile];fprintf(stderr,"STRAY_MODEL_CAPTURE cleanup skipped=read_error\n");return;}
        [input closeFile];unsigned char digest[CC_SHA256_DIGEST_LENGTH];char hex[65];CC_SHA256_Final(digest,&context);
        for(unsigned i=0;i<sizeof(digest);i++)snprintf(hex+i*2,3,"%02x",digest[i]);
        if(![expected isEqualToString:@(hex)]){fprintf(stderr,"STRAY_MODEL_CAPTURE cleanup skipped=digest_mismatch\n");return;}
        NSError *error=nil;BOOL traceRemoved=[files removeItemAtPath:trace error:&error];
        BOOL tarRemoved=traceRemoved && [files removeItemAtPath:tar error:&error];
        fprintf(stderr,"STRAY_MODEL_CAPTURE cleanup file=%s backup_sha256=%s trace_removed=%d tar_removed=%d error=%s\n",name.UTF8String,hex,traceRemoved,tarRemoved,error.description.UTF8String?:"none");
    }});
}

// CoreDevice does not copy symbolic links. A stored ustar stream preserves
// Metal's resource aliases without following or modifying their targets.
static BOOL TarString(char *field, size_t size, NSString *value) {
    NSData *utf8=[value dataUsingEncoding:NSUTF8StringEncoding];
    if(utf8.length>size)return NO;
    memcpy(field,utf8.bytes,utf8.length);return YES;
}

static BOOL TarHeader(NSFileHandle *output, NSString *name, NSString *link,
                      unsigned long long size, NSUInteger mode, char type) {
    unsigned char header[512]={0};
    if(!TarString((char *)header,100,name) || (link && !TarString((char *)header+157,100,link)) ||
       size>077777777777ULL)return NO;
    snprintf((char *)header+100,8,"%07lo",(unsigned long)mode);
    snprintf((char *)header+108,8,"%07o",0);
    snprintf((char *)header+116,8,"%07o",0);
    snprintf((char *)header+124,12,"%011llo",size);
    snprintf((char *)header+136,12,"%011o",0);
    memset(header+148,' ',8);header[156]=type;
    memcpy(header+257,"ustar",5);memcpy(header+263,"00",2);
    unsigned sum=0;for(unsigned i=0;i<512;i++)sum+=header[i];
    snprintf((char *)header+148,7,"%06o",sum);header[155]=' ';
    [output writeData:[NSData dataWithBytes:header length:512]];return YES;
}

static BOOL TarLongLink(NSFileHandle *output, NSString *target) {
    NSString *record=[NSString stringWithFormat:@"linkpath=%@\n",target];
    NSUInteger body=[[record dataUsingEncoding:NSUTF8StringEncoding] length],length=body+2;
    while(length!=body+[[NSString stringWithFormat:@"%lu ",(unsigned long)length] length])
        length=body+[[NSString stringWithFormat:@"%lu ",(unsigned long)length] length];
    NSData *pax=[[NSString stringWithFormat:@"%lu %@",(unsigned long)length,record] dataUsingEncoding:NSUTF8StringEncoding];
    if(!TarHeader(output,@"PaxHeader",nil,pax.length,0644,'x'))return NO;
    [output writeData:pax];
    if(pax.length%512)[output writeData:[NSMutableData dataWithLength:512-pax.length%512]];
    return YES;
}

void StrayArchiveTracePreservingLinks(NSURL *trace) {
    NSFileManager *files=NSFileManager.defaultManager;
    NSString *archive=[trace.path stringByAppendingString:@".tar"];
    if([files fileExistsAtPath:archive])return;
    NSString *partial=[archive stringByAppendingString:@".partial"];
    NSFileHandle *output=nil;NSUInteger regularCount=0,linkCount=0,missingCount=0;
    NSMutableArray *links=[NSMutableArray new];NSError *error=nil;BOOL saved=NO;
    @try {
        if(![files createFileAtPath:partial contents:nil attributes:nil])
            @throw [NSException exceptionWithName:@"TraceArchive" reason:@"Cannot create archive" userInfo:nil];
        output=[NSFileHandle fileHandleForWritingAtPath:partial];
        NSString *base=trace.lastPathComponent;
        if(!TarHeader(output,[base stringByAppendingString:@"/"],nil,0,0755,'5'))
            @throw [NSException exceptionWithName:@"TraceArchive" reason:@"Trace name too long for ustar" userInfo:nil];
        NSDirectoryEnumerator *items=[files enumeratorAtPath:trace.path];
        for(NSString *relative in items){
            NSString *path=[trace.path stringByAppendingPathComponent:relative];
            NSDictionary *attributes=[files attributesOfItemAtPath:path error:&error];
            if(!attributes)@throw [NSException exceptionWithName:@"TraceArchive" reason:error.description userInfo:nil];
            NSString *type=attributes[NSFileType],*name=[base stringByAppendingPathComponent:relative];
            NSUInteger mode=[attributes[NSFilePosixPermissions] unsignedIntegerValue];
            if([type isEqualToString:NSFileTypeSymbolicLink]){
                NSString *target=[files destinationOfSymbolicLinkAtPath:path error:&error];
                BOOL exists=[files fileExistsAtPath:path];
                [links addObject:@{@"path":relative,@"target":target?:@"",@"target_exists":@(exists)}];
                linkCount++;if(!exists)missingCount++;
                if(linkCount<=3)fprintf(stderr,"STRAY_MODEL_CAPTURE link file=%s target=%s exists=%d\n",relative.UTF8String,target.UTF8String,exists);
                BOOL longLink=[[target dataUsingEncoding:NSUTF8StringEncoding] length]>100;
                if(!target || (longLink && !TarLongLink(output,target)) || !TarHeader(output,name,longLink?nil:target,0,mode,'2'))
                    @throw [NSException exceptionWithName:@"TraceArchive" reason:@"Unsupported symbolic link header" userInfo:nil];
            }else if([type isEqualToString:NSFileTypeDirectory]){
                if(!TarHeader(output,[name stringByAppendingString:@"/"],nil,0,mode,'5'))
                    @throw [NSException exceptionWithName:@"TraceArchive" reason:@"Directory name too long" userInfo:nil];
            }else if([type isEqualToString:NSFileTypeRegular]){
                unsigned long long length=[attributes[NSFileSize] unsignedLongLongValue];
                if(!TarHeader(output,name,nil,length,mode,'0'))
                    @throw [NSException exceptionWithName:@"TraceArchive" reason:@"Unsupported file header" userInfo:nil];
                NSFileHandle *input=[NSFileHandle fileHandleForReadingAtPath:path];
                if(!input)@throw [NSException exceptionWithName:@"TraceArchive" reason:@"Cannot open capture resource" userInfo:nil];
                unsigned long long remaining=length;
                while(remaining){@autoreleasepool{
                    NSData *part=[input readDataOfLength:(NSUInteger)MIN(remaining,1024ULL*1024)];
                    if(!part.length)@throw [NSException exceptionWithName:@"TraceArchive" reason:@"Truncated capture resource" userInfo:nil];
                    [output writeData:part];remaining-=part.length;
                }}
                [input closeFile];
                if(length%512)[output writeData:[NSMutableData dataWithLength:512-length%512]];
                regularCount++;
            }else @throw [NSException exceptionWithName:@"TraceArchive" reason:@"Unsupported capture entry" userInfo:nil];
        }
        [output writeData:[NSMutableData dataWithLength:1024]];[output closeFile];output=nil;
        NSData *manifest=[NSJSONSerialization dataWithJSONObject:@{@"trace":trace.path,@"links":links,@"missing_link_targets":@(missingCount)} options:NSJSONWritingPrettyPrinted error:&error];
        if(![manifest writeToFile:[archive stringByAppendingString:@".links.json"] options:NSDataWritingAtomic error:&error])
            @throw [NSException exceptionWithName:@"TraceArchive" reason:error.description userInfo:nil];
        saved=[files moveItemAtPath:partial toPath:archive error:&error];
    }@catch(NSException *exception){
        error=[NSError errorWithDomain:@"StrayTraceArchive" code:1 userInfo:@{NSLocalizedDescriptionKey:exception.reason?:exception.name}];
    }@finally{[output closeFile];}
    fprintf(stderr,"STRAY_MODEL_CAPTURE tar file=%s saved=%d regular=%lu links=%lu missing_targets=%lu error=%s\n",archive.lastPathComponent.UTF8String,saved,(unsigned long)regularCount,(unsigned long)linkCount,(unsigned long)missingCount,error.description.UTF8String?:"none");
}
