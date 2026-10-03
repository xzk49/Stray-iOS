#import <AppKit/AppKit.h>
#import <ImageIO/ImageIO.h>
int main(int argc,char **argv){@autoreleasepool{
    if(argc!=3)return 1;
    NSBitmapImageRep *source=[NSBitmapImageRep imageRepWithData:[NSData dataWithContentsOfFile:@(argv[1])]];
    CGImageRef image=source.CGImage;if(!image)return 2;
    size_t w=CGImageGetWidth(image),h=CGImageGetHeight(image);
    CGColorSpaceRef space=CGColorSpaceCreateDeviceRGB();
    CGContextRef context=CGBitmapContextCreate(NULL,w,h,8,w*4,space,kCGImageAlphaNoneSkipLast);
    CGColorSpaceRelease(space);if(!context)return 3;
    CGContextSetRGBFillColor(context,0,0,0,1);CGContextFillRect(context,CGRectMake(0,0,w,h));
    CGContextDrawImage(context,CGRectMake(0,0,w,h),image);
    CGImageRef opaque=CGBitmapContextCreateImage(context);
    CGImageDestinationRef output=CGImageDestinationCreateWithURL((__bridge CFURLRef)[NSURL fileURLWithPath:@(argv[2])],CFSTR("public.png"),1,NULL);
    if(!output)return 4;CGImageDestinationAddImage(output,opaque,NULL);BOOL saved=CGImageDestinationFinalize(output);
    CFRelease(output);CGImageRelease(opaque);CGContextRelease(context);return saved?0:5;
}}
