#import "AppKitBridge.h"
#import <ImageIO/ImageIO.h>
#import <objc/message.h>
#import "GameRoot.h"

static void UI(void (^block)(void)) { if(NSThread.isMainThread)block();else dispatch_sync(dispatch_get_main_queue(),block); }

#define NSFont StrayFont
#define NSColor StrayColor
@interface NSFont : NSObject @end
@implementation NSFont
+ (id)systemFontOfSize:(CGFloat)size { return [UIFont systemFontOfSize:size]; }
+ (id)boldSystemFontOfSize:(CGFloat)size { return [UIFont boldSystemFontOfSize:size]; }
+ (id)fontWithName:(NSString *)name size:(CGFloat)size { return [UIFont fontWithName:name size:size]; }
+ (CGFloat)systemFontSize { return UIFont.systemFontSize; }
+ (CGFloat)smallSystemFontSize { return UIFont.smallSystemFontSize; }
@end
@interface NSColor : NSObject @end
@implementation NSColor
+ (id)clearColor { return UIColor.clearColor; }
+ (id)blackColor { return UIColor.blackColor; }
+ (id)whiteColor { return UIColor.whiteColor; }
+ (id)colorWithCalibratedRed:(CGFloat)r green:(CGFloat)g blue:(CGFloat)b alpha:(CGFloat)a { return [UIColor colorWithRed:r green:g blue:b alpha:a]; }
+ (id)colorWithDeviceRed:(CGFloat)r green:(CGFloat)g blue:(CGFloat)b alpha:(CGFloat)a { return [UIColor colorWithRed:r green:g blue:b alpha:a]; }
+ (id)colorWithCalibratedWhite:(CGFloat)w alpha:(CGFloat)a { return [UIColor colorWithWhite:w alpha:a]; }
+ (id)colorWithCGColor:(CGColorRef)color { return [UIColor colorWithCGColor:color]; }
@end
@implementation UIColor (StrayColorSpace)
- (id)colorUsingColorSpaceName:(NSString *)name { CGFloat r,g,b,a;return [self getRed:&r green:&g blue:&b alpha:&a]?[UIColor colorWithRed:r green:g blue:b alpha:a]:nil; }
@end

@interface NSWorkspace : NSObject
@property(nonatomic, strong) NSNotificationCenter *notificationCenter;
@end
@implementation NSWorkspace
+ (instancetype)sharedWorkspace { static NSWorkspace *w;static dispatch_once_t once;dispatch_once(&once,^{w=[self new];w.notificationCenter=[NSNotificationCenter new];});return w; }
- (NSString *)fullPathForApplication:(NSString *)name {
    if(!name.length)return nil;
    NSString *root=StrayRootFromHostBundle(NSBundle.mainBundle);
    NSDictionary *guest=root?[NSDictionary dictionaryWithContentsOfFile:[root stringByAppendingPathComponent:@"Contents/Info.plist"]]:nil;
    NSString *base=name.lastPathComponent.stringByDeletingPathExtension;
    NSArray *guestNames=@[guest[@"CFBundleIdentifier"]?:@"",guest[@"CFBundleName"]?:@"",guest[@"CFBundleExecutable"]?:@"",@"Stray"];
    if(root && ([name isEqualToString:guest[@"CFBundleIdentifier"]] || [guestNames containsObject:base]))return root;
    NSDictionary *host=NSBundle.mainBundle.infoDictionary;
    if([name isEqualToString:host[@"CFBundleIdentifier"]] || [base isEqualToString:host[@"CFBundleName"]])return NSBundle.mainBundle.bundlePath;
    NSLog(@"STRAY_APPKIT application_unavailable %@",name);
    return nil; // Mac desktop utilities are not installed in this iOS sandbox.
}
- (BOOL)isFilePackageAtPath:(NSString *)path {
    NSNumber *package=nil;
    [[NSURL fileURLWithPath:path] getResourceValue:&package forKey:NSURLIsPackageKey error:nil];
    return package.boolValue;
}
- (BOOL)isVoiceOverEnabled { return UIAccessibilityIsVoiceOverRunning(); }
- (BOOL)accessibilityDisplayShouldIncreaseContrast { return UIAccessibilityDarkerSystemColorsEnabled(); }
- (BOOL)accessibilityDisplayShouldReduceMotion { return UIAccessibilityIsReduceMotionEnabled(); }
- (BOOL)accessibilityDisplayShouldInvertColors { return UIAccessibilityIsInvertColorsEnabled(); }
- (BOOL)openURL:(NSURL *)url { __block BOOL can;UI(^{can=[UIApplication.sharedApplication canOpenURL:url];if(can)[UIApplication.sharedApplication openURL:url options:@{} completionHandler:nil];});return can; }
@end

@interface NSMenuItem : NSObject
@property(nonatomic, copy) NSString *title;
@property(nonatomic) SEL action;
@property(nonatomic, weak) id target;
@property(nonatomic, strong) id submenu;
@property(nonatomic, copy) NSString *keyEquivalent;
@property(nonatomic) NSUInteger keyEquivalentModifierMask;
@property(nonatomic) BOOL enabled;
@property(nonatomic) BOOL hidden;
@property(nonatomic) NSInteger state;
@property(nonatomic) NSInteger tag;
@property(nonatomic) BOOL separator;
@end
@implementation NSMenuItem
- (instancetype)initWithTitle:(NSString *)title action:(SEL)action keyEquivalent:(NSString *)key { if((self=[super init])){self.title=title;self.action=action;self.keyEquivalent=key;self.enabled=YES;}return self; }
+ (instancetype)separatorItem { NSMenuItem *i=[self new];i.separator=YES;return i; }
- (BOOL)isSeparatorItem { return self.separator; }
- (BOOL)isEnabled { return self.enabled; }
- (void)performClick:(id)sender { if(self.enabled && self.action && [self.target respondsToSelector:self.action])((void(*)(id,SEL,id))objc_msgSend)(self.target,self.action,self); }
@end
@interface NSMenu : NSObject
@property(nonatomic, copy) NSString *title;
@property(nonatomic) BOOL autoenablesItems;
@property(nonatomic, strong) NSMutableArray<NSMenuItem *> *itemArray;
@property(nonatomic, weak) id delegate;
@end
@implementation NSMenu
- (instancetype)init { return [self initWithTitle:@""]; }
- (instancetype)initWithTitle:(NSString *)title { if((self=[super init])){self.title=title;self.itemArray=[NSMutableArray new];}return self; }
- (void)addItem:(NSMenuItem *)item { [self.itemArray addObject:item]; }
- (id)addItemWithTitle:(NSString *)title action:(SEL)action keyEquivalent:(NSString *)key { NSMenuItem *i=[[NSMenuItem alloc]initWithTitle:title action:action keyEquivalent:key];[self addItem:i];return i; }
- (void)insertItem:(id)item atIndex:(NSInteger)index { [self.itemArray insertObject:item atIndex:index]; }
- (void)removeItem:(id)item { [self.itemArray removeObject:item]; }
- (void)removeItemAtIndex:(NSInteger)index { [self.itemArray removeObjectAtIndex:index]; }
- (void)removeAllItems { [self.itemArray removeAllObjects]; }
- (NSInteger)numberOfItems { return self.itemArray.count; }
- (id)itemAtIndex:(NSInteger)index { return index>=0 && index<self.itemArray.count?self.itemArray[index]:nil; }
- (id)itemWithTitle:(NSString *)title { for(NSMenuItem *i in self.itemArray)if([i.title isEqual:title])return i;return nil; }
- (id)itemWithTag:(NSInteger)tag { for(NSMenuItem *i in self.itemArray)if(i.tag==tag)return i;return nil; }
- (void)update {
    SEL refresh=NSSelectorFromString(@"menuNeedsUpdate:");
    if([self.delegate respondsToSelector:refresh])((void(*)(id,SEL,id))objc_msgSend)(self.delegate,refresh,self);
    for(NSMenuItem *item in [self.itemArray copy]){
        if(self.autoenablesItems && !item.separator && item.action){
            SEL validate=NSSelectorFromString(@"validateMenuItem:");
            item.enabled=[item.target respondsToSelector:validate]?((BOOL(*)(id,SEL,id))objc_msgSend)(item.target,validate,item):[item.target respondsToSelector:item.action];
        }
        if([item.submenu respondsToSelector:@selector(update)])[item.submenu update];
    }
}
@end

@interface NSCursor : NSObject
@property(nonatomic, strong) id image;
@property(nonatomic) CGPoint hotSpot;
@property(nonatomic, copy) NSString *shape;
@end
static NSInteger CursorHideDepth;
static NSCursor *CurrentCursor;
@implementation NSCursor
+ (instancetype)cursor:(NSString *)shape { NSCursor *c=[self new];c.shape=shape;return c; }
+ (instancetype)arrowCursor { return [self cursor:@"arrow"]; }
+ (instancetype)IBeamCursor { return [self cursor:@"text"]; }
+ (instancetype)crosshairCursor { return [self cursor:@"crosshair"]; }
+ (instancetype)pointingHandCursor { return [self cursor:@"hand"]; }
+ (instancetype)openHandCursor { return [self cursor:@"open-hand"]; }
+ (instancetype)closedHandCursor { return [self cursor:@"closed-hand"]; }
+ (instancetype)resizeLeftRightCursor { return [self cursor:@"resize-horizontal"]; }
+ (instancetype)resizeUpDownCursor { return [self cursor:@"resize-vertical"]; }
+ (instancetype)operationNotAllowedCursor { return [self cursor:@"disabled"]; }
+ (instancetype)currentCursor { return CurrentCursor?:[self arrowCursor]; }
+ (void)hide { CursorHideDepth++; }
+ (void)unhide { if(CursorHideDepth>0)CursorHideDepth--; }
- (instancetype)initWithImage:(id)image hotSpot:(CGPoint)point { if((self=[super init])){self.image=image;self.hotSpot=point;}return self; }
- (void)set { CurrentCursor=self; }
@end

@interface NSBitmapImageRep : NSObject
@property(nonatomic, strong) NSMutableData *data;
@property(nonatomic) NSInteger pixelsWide;
@property(nonatomic) NSInteger pixelsHigh;
@property(nonatomic) NSInteger bytesPerRow;
@property(nonatomic) NSInteger samplesPerPixel;
@property(nonatomic) BOOL hasAlpha;
- (CGImageRef)CGImage CF_RETURNS_RETAINED;
@end
@implementation NSBitmapImageRep
- (instancetype)initWithBitmapDataPlanes:(unsigned char **)planes pixelsWide:(NSInteger)width pixelsHigh:(NSInteger)height bitsPerSample:(NSInteger)bits samplesPerPixel:(NSInteger)samples hasAlpha:(BOOL)alpha isPlanar:(BOOL)planar colorSpaceName:(NSString *)name bytesPerRow:(NSInteger)row bitsPerPixel:(NSInteger)bpp {
    if(planar || bits!=8 || (samples!=3 && samples!=4) || width<=0 || height<=0 || (row && row<width*samples))
        [NSException raise:NSInvalidArgumentException format:@"Unsupported bitmap layout"];
    if((self=[super init])){self.pixelsWide=width;self.pixelsHigh=height;self.bytesPerRow=row?:width*samples;self.samplesPerPixel=samples;self.hasAlpha=alpha;
        self.data=planes&&planes[0]?[NSMutableData dataWithBytes:planes[0] length:self.bytesPerRow*height]:[NSMutableData dataWithLength:self.bytesPerRow*height];}return self;
}
- (unsigned char *)bitmapData { return self.data.mutableBytes; }
- (CGImageRef)CGImage {
    CGColorSpaceRef space=CGColorSpaceCreateDeviceRGB();CGDataProviderRef provider=CGDataProviderCreateWithCFData((__bridge CFDataRef)self.data);
    CGBitmapInfo info=(CGBitmapInfo)(self.hasAlpha?kCGImageAlphaLast:kCGImageAlphaNone);
    if(self.samplesPerPixel==4 && !self.hasAlpha)info=(CGBitmapInfo)kCGImageAlphaNoneSkipLast;
    CGImageRef image=CGImageCreate(self.pixelsWide,self.pixelsHigh,8,self.samplesPerPixel*8,self.bytesPerRow,space,info,provider,NULL,NO,kCGRenderingIntentDefault);
    CGDataProviderRelease(provider);CGColorSpaceRelease(space);return image;
}
@end
@interface NSImage : NSObject
@property(nonatomic, strong) UIImage *nativeImage;
@property(nonatomic) CGSize size;
@end
@implementation NSImage
- (instancetype)initWithSize:(CGSize)size { if((self=[super init]))self.size=size;return self; }
- (instancetype)initWithContentsOfFile:(NSString *)file { if((self=[super init])){self.nativeImage=[UIImage imageWithContentsOfFile:file];self.size=self.nativeImage.size;}return self.nativeImage?self:nil; }
- (instancetype)initWithData:(NSData *)data { if((self=[super init])){self.nativeImage=[UIImage imageWithData:data];self.size=self.nativeImage.size;}return self.nativeImage?self:nil; }
+ (instancetype)imageNamed:(NSString *)name { NSImage *i=[self new];i.nativeImage=[UIImage imageNamed:name];i.size=i.nativeImage.size;return i.nativeImage?i:nil; }
- (void)addRepresentation:(NSBitmapImageRep *)rep { CGImageRef image=[rep CGImage];self.nativeImage=[UIImage imageWithCGImage:image];CGImageRelease(image); }
- (CGImageRef)CGImageForProposedRect:(CGRect *)rect context:(id)context hints:(NSDictionary *)hints { return self.nativeImage.CGImage; }
@end

@interface NSPasteboardItem : NSObject
@property(nonatomic, strong) NSMutableDictionary *values;
@end
@implementation NSPasteboardItem
- (instancetype)init { if((self=[super init]))self.values=[NSMutableDictionary new];return self; }
- (BOOL)setString:(NSString *)string forType:(NSString *)type { self.values[type]=string;return YES; }
- (BOOL)setData:(NSData *)data forType:(NSString *)type { self.values[type]=data;return YES; }
- (id)stringForType:(NSString *)type { id value=self.values[type];return [value isKindOfClass:NSString.class]?value:nil; }
- (id)dataForType:(NSString *)type { id value=self.values[type];return [value isKindOfClass:NSData.class]?value:nil; }
- (NSArray *)types { return self.values.allKeys; }
@end
@interface NSPasteboard : NSObject @end
@implementation NSPasteboard
+ (instancetype)generalPasteboard { static NSPasteboard *p;static dispatch_once_t once;dispatch_once(&once,^{p=[self new];});return p; }
- (NSInteger)changeCount { return UIPasteboard.generalPasteboard.changeCount; }
- (NSInteger)clearContents { UIPasteboard.generalPasteboard.items=@[];return self.changeCount; }
- (BOOL)setString:(NSString *)string forType:(NSString *)type { if([type containsString:@"text"]){UIPasteboard.generalPasteboard.string=string;return YES;}[UIPasteboard.generalPasteboard setValue:string forPasteboardType:type];return YES; }
- (NSString *)stringForType:(NSString *)type { if([type containsString:@"text"])return UIPasteboard.generalPasteboard.string;id value=[UIPasteboard.generalPasteboard valueForPasteboardType:type];return [value isKindOfClass:NSString.class]?value:nil; }
- (BOOL)writeObjects:(NSArray *)objects { NSMutableArray *items=[NSMutableArray new];for(id object in objects){if([object isKindOfClass:NSPasteboardItem.class])[items addObject:((NSPasteboardItem *)object).values];else if([object isKindOfClass:NSString.class])[items addObject:@{@"public.utf8-plain-text":object}];else return NO;}UIPasteboard.generalPasteboard.items=items;return YES; }
@end

@interface NSScrollView : NSView
@property(nonatomic, strong) NSView *documentView;
@property(nonatomic) BOOL hasVerticalScroller;
@property(nonatomic) BOOL hasHorizontalScroller;
@end
@implementation NSScrollView
- (instancetype)initWithFrame:(CGRect)frame { if((self=[super initWithFrame:frame]))UI(^{self.nativeView=[[UIScrollView alloc]initWithFrame:frame];});return self; }
- (void)setDocumentView:(NSView *)view { [_documentView removeFromSuperview];_documentView=view;[self addSubview:view];UI(^{((UIScrollView *)self.nativeView).contentSize=view.frame.size;}); }
- (NSView *)contentView { return self; }
- (void)setHasVerticalScroller:(BOOL)value { _hasVerticalScroller=value;UI(^{((UIScrollView *)self.nativeView).showsVerticalScrollIndicator=value;}); }
- (void)setHasHorizontalScroller:(BOOL)value { _hasHorizontalScroller=value;UI(^{((UIScrollView *)self.nativeView).showsHorizontalScrollIndicator=value;}); }
@end
@interface NSTextView : NSView
@property(nonatomic, copy) NSString *string;
@property(nonatomic) NSRange selectedRange;
@property(nonatomic) BOOL editable;
@property(nonatomic) BOOL selectable;
@property(nonatomic) BOOL richText;
@property(nonatomic) BOOL drawsBackground;
@property(nonatomic, strong) id font;
@end
@implementation NSTextView
- (instancetype)initWithFrame:(CGRect)frame { if((self=[super initWithFrame:frame]))UI(^{self.nativeView=[[UITextView alloc]initWithFrame:frame];});return self; }
- (void)setString:(NSString *)value { _string=[value copy];UI(^{((UITextView *)self.nativeView).text=value;}); }
- (void)setSelectedRange:(NSRange)range { _selectedRange=range;UI(^{((UITextView *)self.nativeView).selectedRange=range;}); }
- (void)setFont:(id)font { _font=font;UI(^{((UITextView *)self.nativeView).font=font;}); }
- (void)setEditable:(BOOL)value { _editable=value;UI(^{((UITextView *)self.nativeView).editable=value;}); }
- (void)setSelectable:(BOOL)value { _selectable=value;UI(^{((UITextView *)self.nativeView).selectable=value;}); }
- (id)textStorage { return ((UITextView *)self.nativeView).textStorage; }
- (NSRange)markedRange { UITextRange *range=((UITextView *)self.nativeView).markedTextRange;return range?NSMakeRange(0,0):NSMakeRange(NSNotFound,0); }
@end

@interface NSAccessibilityElement : UIAccessibilityElement
@property(nonatomic, copy) NSString *accessibilityRole;
@property(nonatomic, copy) NSString *accessibilitySubrole;
@property(nonatomic, strong) id accessibilityParent;
@property(nonatomic, strong) NSArray *accessibilityChildren;
@end
@implementation NSAccessibilityElement
+ (instancetype)accessibilityElementWithRole:(NSString *)role frame:(CGRect)frame label:(NSString *)label parent:(id)parent {
    id container=[parent isKindOfClass:NSView.class]?((NSView *)parent).nativeView:parent;
    NSAccessibilityElement *e=[[self alloc]initWithAccessibilityContainer:container];e.accessibilityRole=role;e.accessibilityFrame=frame;e.accessibilityLabel=label;e.accessibilityParent=parent;return e;
}
- (void)setAccessibilityRole:(NSString *)role { _accessibilityRole=[role copy];
    NSDictionary *traits=@{@"AXButton":@(UIAccessibilityTraitButton),@"AXLink":@(UIAccessibilityTraitLink),@"AXImage":@(UIAccessibilityTraitImage),@"AXStaticText":@(UIAccessibilityTraitStaticText)};self.accessibilityTraits=[traits[role] unsignedLongLongValue]; }
- (BOOL)isAccessibilityElement { return YES; }
- (void)setAccessibilityFocused:(BOOL)focused { if(focused)UIAccessibilityPostNotification(UIAccessibilityScreenChangedNotification,self); }
@end
void NSAccessibilityPostNotification(id element, NSString *notification) { UI(^{UIAccessibilityPostNotification(UIAccessibilityLayoutChangedNotification,element);}); }
void NSAccessibilityPostNotificationWithUserInfo(id element,NSString *notification,NSDictionary *info) { id announcement=info[@"NSAccessibilityAnnouncementKey"];UI(^{UIAccessibilityPostNotification(announcement?UIAccessibilityAnnouncementNotification:UIAccessibilityLayoutChangedNotification,announcement?:element);}); }
NSString *NSAccessibilityRoleDescription(NSString *role,NSString *subrole) { return subrole?:role; }

@interface NSAlert : NSObject
@property(nonatomic, copy) NSString *messageText;
@property(nonatomic, copy) NSString *informativeText;
@property(nonatomic) NSInteger alertStyle;
@property(nonatomic, strong) NSMutableArray<NSString *> *buttons;
@end
@implementation NSAlert
- (instancetype)init { if((self=[super init]))self.buttons=[NSMutableArray new];return self; }
- (id)addButtonWithTitle:(NSString *)title { [self.buttons addObject:title];return title; }
- (NSInteger)runModal { __block NSInteger result=0;NSLog(@"STRAY_GAME_ALERT %@ %@",self.messageText,self.informativeText);
    UI(^{UIAlertController *alert=[UIAlertController alertControllerWithTitle:self.messageText message:self.informativeText preferredStyle:UIAlertControllerStyleAlert];
        NSArray *buttons=self.buttons.count?self.buttons:@[@"OK"];for(NSUInteger i=0;i<buttons.count;i++)[alert addAction:[UIAlertAction actionWithTitle:buttons[i] style:UIAlertActionStyleDefault handler:^(UIAlertAction *a){result=1000+i;}]];
        UIWindow *window=NSApp.keyWindow.nativeWindow?:UIApplication.sharedApplication.windows.firstObject;
        [window.rootViewController presentViewController:alert animated:YES completion:nil]; });
    while(!result){if(NSThread.isMainThread)[NSRunLoop.mainRunLoop runMode:NSDefaultRunLoopMode beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.02]];else[NSThread sleepForTimeInterval:0.02];}return result;
}
@end
NSInteger NSRunInformationalAlertPanel(NSString *title,NSString *format,NSString *defaultButton,NSString *alternate,NSString *other,...) {
    va_list args;va_start(args,other);NSString *text=[[NSString alloc]initWithFormat:format arguments:args];va_end(args);NSAlert *a=[NSAlert new];a.messageText=title;a.informativeText=text;
    [a addButtonWithTitle:defaultButton?:@"OK"];if(alternate)[a addButtonWithTitle:alternate];if(other)[a addButtonWithTitle:other];return [a runModal]-999;
}
