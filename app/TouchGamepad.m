#import "TouchGamepad.h"
#import <GameController/GameController.h>
#import <objc/runtime.h>
#include <stdatomic.h>
#include <math.h>
#include <stdio.h>

// Xbox control names and the face-button diamond follow Geocld/XStreaming.
// See THIRD_PARTY_NOTICES.txt. The transport is the game's existing Apple
// controller interface: no network, keyboard emulation or system HID device.
static GCController *TouchController;
static NSObject *StateLock;
static atomic_bool ControllerEnabled;
static atomic_uint PollCount, ActivePollCount;
static NSArray *(*OriginalControllers)(id,SEL);
static GCController *(*OriginalCapture)(id,SEL);
static NSString *(*OriginalCategory)(id,SEL);
static unsigned InputMessages;
static BOOL ReportPending;
static NSMutableDictionary *LastInputs;

static NSString *ConfigPath(void){return [NSHomeDirectory() stringByAppendingPathComponent:@"Documents/StrayTouchLayout.plist"];}
static void Report(void){
    if(ReportPending)return;ReportPending=YES;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,250*NSEC_PER_MSEC),dispatch_get_main_queue(),^{
        ReportPending=NO;NSDictionary *inputs;@synchronized(StateLock){inputs=[LastInputs copy];}
        NSDictionary *report=@{@"enabled":@(atomic_load(&ControllerEnabled)),@"snapshot":@(TouchController.isSnapshot),
            @"polls":@(atomic_load(&PollCount)),@"activePolls":@(atomic_load(&ActivePollCount)),@"inputs":inputs?:@{},
            @"mapping":@{@"A":@"buttonA",@"B":@"buttonB",@"X":@"buttonX",@"Y":@"buttonY",
                @"LeftShoulder":@"leftShoulder",@"RightShoulder":@"rightShoulder",@"LeftTrigger":@"leftTrigger",@"RightTrigger":@"rightTrigger",
                @"LeftThumb":@"leftThumbstickButton",@"RightThumb":@"rightThumbstickButton",@"View":@"buttonOptions",@"Menu":@"buttonMenu",@"Nexus":@"buttonHome"}};
        NSData *data=[NSJSONSerialization dataWithJSONObject:report options:NSJSONWritingPrettyPrinted error:nil];
        [data writeToFile:[NSHomeDirectory() stringByAppendingPathComponent:@"Documents/StrayTouchReport.json"] atomically:YES];
    });
}
static NSArray *Controllers(id cls,SEL cmd){
    NSArray *real=OriginalControllers(cls,cmd);
    if(!atomic_load(&ControllerEnabled) || !TouchController)return real;
    if([real containsObject:TouchController])return real;
    return [@[TouchController] arrayByAddingObjectsFromArray:real?:@[]];
}
static NSString *TouchCategory(id controller,SEL cmd){
    return controller==TouchController?@"Xbox One":OriginalCategory(controller,cmd);
}
static GCController *Capture(id controller,SEL cmd){
    if(controller!=TouchController)return OriginalCapture(controller,cmd);
    GCController *snapshot;BOOL active=NO;unsigned polls;
    @synchronized(StateLock){
        snapshot=OriginalCapture(controller,cmd);
        polls=atomic_fetch_add(&PollCount,1)+1;
        for(id value in LastInputs.allValues){if([value isKindOfClass:NSNumber.class] && fabs([value doubleValue])>0.001){active=YES;break;}}
    }
    if(active){unsigned n=atomic_fetch_add(&ActivePollCount,1)+1;if(n==1 || n%600==0)fprintf(stderr,"STRAY_TOUCH_CONTROLLER active_poll=%u polls=%u\n",n,polls);}
    if(polls==1)fprintf(stderr,"STRAY_TOUCH_CONTROLLER first_native_poll=1\n");
    return snapshot;
}
static GCControllerButtonInput *Button(NSString *name){
    GCExtendedGamepad *g=TouchController.extendedGamepad;
    NSDictionary *map=@{@"A":g.buttonA,@"B":g.buttonB,@"X":g.buttonX,@"Y":g.buttonY,
        @"LeftShoulder":g.leftShoulder,@"RightShoulder":g.rightShoulder,@"LeftTrigger":g.leftTrigger,@"RightTrigger":g.rightTrigger,
        @"Menu":g.buttonMenu};
    if([name isEqual:@"View"])return g.buttonOptions;
    if([name isEqual:@"Nexus"])return g.buttonHome;
    if([name isEqual:@"LeftThumb"])return g.leftThumbstickButton;
    if([name isEqual:@"RightThumb"])return g.rightThumbstickButton;
    return map[name];
}
static unsigned SetButton(NSString *name,float value){
    unsigned polls;
    @synchronized(StateLock){[Button(name) setValue:value];LastInputs[name]=@(value);polls=atomic_load(&PollCount);}
    if(InputMessages++<128)fprintf(stderr,"STRAY_TOUCH_INPUT name=%s value=%.2f\n",name.UTF8String,value);
    Report();
    return polls;
}
static unsigned SetAxes(NSString *name,float x,float y){
    unsigned polls;
    @synchronized(StateLock){
        GCExtendedGamepad *g=TouchController.extendedGamepad;
        GCControllerDirectionPad *axis=[name isEqual:@"LeftStick"]?g.leftThumbstick:([name isEqual:@"RightStick"]?g.rightThumbstick:g.dpad);
        [axis setValueForXAxis:x yAxis:y];LastInputs[[name stringByAppendingString:@"X"]]=@(x);LastInputs[[name stringByAppendingString:@"Y"]]=@(y);
        polls=atomic_load(&PollCount);
    }
    Report();
    return polls;
}
static void ResetState(void){
    @synchronized(StateLock){
        for(NSString *name in @[@"A",@"B",@"X",@"Y",@"LeftShoulder",@"RightShoulder",@"LeftTrigger",@"RightTrigger",@"Menu",@"View",@"Nexus",@"LeftThumb",@"RightThumb"])[Button(name) setValue:0];
        GCExtendedGamepad *g=TouchController.extendedGamepad;
        [g.dpad setValueForXAxis:0 yAxis:0];[g.leftThumbstick setValueForXAxis:0 yAxis:0];[g.rightThumbstick setValueForXAxis:0 yAxis:0];[LastInputs removeAllObjects];
    }
    Report();
}

@class StrayTouchOverlay;
@interface StrayTouchControl : UIView
@property(nonatomic, copy) NSString *controlName;
@property(nonatomic, weak) StrayTouchOverlay *owner;
@property(nonatomic, strong) UITouch *heldTouch;
@property(nonatomic) NSUInteger generation;
@property(nonatomic) unsigned activationPoll;
@property(nonatomic) BOOL pressed;
@property(nonatomic) CGPoint stick;
- (void)cancelInput;
@end
@interface StrayTouchOverlay : UIView
@property(nonatomic, strong) NSMutableDictionary<NSString *,StrayTouchControl *> *controls;
@property(nonatomic, strong) NSMutableDictionary *config;
@property(nonatomic, strong) UIButton *ball;
@property(nonatomic, strong) UIView *panel;
@property(nonatomic, weak) UIView *canvas;
@property(nonatomic) BOOL editing;
@property(nonatomic) CGFloat sensitivity;
@property(nonatomic) CGFloat deadzone;
- (void)save;
- (void)cancelAll;
- (void)openSettings;
- (void)controlDragged:(UIPanGestureRecognizer *)gesture;
- (void)controlScaled:(UIPinchGestureRecognizer *)gesture;
@end

@implementation StrayTouchControl
- (instancetype)initWithFrame:(CGRect)frame {
    if((self=[super initWithFrame:frame])){self.backgroundColor=UIColor.clearColor;self.isAccessibilityElement=YES;self.accessibilityTraits=UIAccessibilityTraitButton;self.multipleTouchEnabled=NO;}
    return self;
}
- (BOOL)isAxis{return [self.controlName hasSuffix:@"Stick"] || [self.controlName isEqual:@"DPad"];}
- (void)drawRect:(CGRect)rect {
    CGRect r=CGRectInset(self.bounds,2,2);BOOL stick=[self isAxis];
    UIBezierPath *base=[UIBezierPath bezierPathWithRoundedRect:r cornerRadius:MIN(r.size.width,r.size.height)/2];
    [[UIColor colorWithWhite:self.pressed?0.8:0.08 alpha:self.pressed?0.55:0.35] setFill];[base fill];
    [[UIColor colorWithWhite:1 alpha:0.65] setStroke];base.lineWidth=1.4;[base stroke];
    NSString *text=self.controlName;
    NSDictionary *titles=@{@"LeftShoulder":@"LB",@"RightShoulder":@"RB",@"LeftTrigger":@"LT",@"RightTrigger":@"RT",@"LeftThumb":@"L3",@"RightThumb":@"R3",@"LeftStick":@"L",@"RightStick":@"R",@"Menu":@"≡",@"View":@"▣",@"Nexus":@"⌂",@"DPad":@"✚"};
    text=titles[text]?:text;
    UIColor *color=UIColor.whiteColor;
    if([text isEqual:@"A"])color=[UIColor colorWithRed:.48 green:.82 blue:.18 alpha:1];
    if([text isEqual:@"B"])color=[UIColor colorWithRed:1 green:.30 blue:.25 alpha:1];
    if([text isEqual:@"X"])color=[UIColor colorWithRed:.15 green:.68 blue:1 alpha:1];
    if([text isEqual:@"Y"])color=[UIColor colorWithRed:1 green:.8 blue:.16 alpha:1];
    CGFloat size=stick?21:MIN(24,self.bounds.size.height*.4);
    NSDictionary *attrs=@{NSFontAttributeName:[UIFont systemFontOfSize:size weight:UIFontWeightSemibold],NSForegroundColorAttributeName:color};
    CGSize s=[text sizeWithAttributes:attrs];[text drawAtPoint:CGPointMake((rect.size.width-s.width)/2,(rect.size.height-s.height)/2) withAttributes:attrs];
    if([self.controlName hasSuffix:@"Stick"]){
        CGFloat radius=r.size.width*.24;CGPoint c=CGPointMake(CGRectGetMidX(r)+self.stick.x*r.size.width*.24,CGRectGetMidY(r)-self.stick.y*r.size.height*.24);
        UIBezierPath *knob=[UIBezierPath bezierPathWithOvalInRect:CGRectMake(c.x-radius,c.y-radius,radius*2,radius*2)];
        [[UIColor colorWithWhite:1 alpha:.3] setFill];[knob fill];
    }
    if(self.owner.editing){[[UIColor colorWithRed:.25 green:.85 blue:1 alpha:1] setStroke];base.lineWidth=2;[base stroke];}
}
- (void)move:(UITouch *)touch {
    if(![self isAxis])return;
    CGPoint p=[touch locationInView:self];float x=(p.x-self.bounds.size.width/2)/(self.bounds.size.width*.35),y=-(p.y-self.bounds.size.height/2)/(self.bounds.size.height*.35);
    float length=hypotf(x,y);if(length>1){x/=length;y/=length;length=1;}
    if([self.controlName isEqual:@"DPad"]){if(length<.3){x=0;y=0;}else{x=fabsf(x)>.35?copysignf(1,x):0;y=fabsf(y)>.35?copysignf(1,y):0;}}
    else {float dead=self.owner.deadzone;if(length<=dead){x=0;y=0;}else{float magnitude=MIN(1,(length-dead)/(1-dead)*self.owner.sensitivity);x=x/length*magnitude;y=y/length*magnitude;}}
    self.stick=CGPointMake(x,y);unsigned polls=SetAxes(self.controlName,x,y);
    if(x!=0 || y!=0)self.activationPoll=polls;
    [self setNeedsDisplay];
}
- (void)releaseGeneration:(NSUInteger)generation attempts:(unsigned)attempts {
    if(self.generation!=generation || self.pressed)return;
    // XStreaming holds a released button for 50 ms. At a slow game frame,
    // keep it until the native controller has sampled it, bounded to 500 ms.
    if(atomic_load(&PollCount)==self.activationPoll && attempts<10){
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW,50*NSEC_PER_MSEC),dispatch_get_main_queue(),^{[self releaseGeneration:generation attempts:attempts+1];});return;
    }
    if([self isAxis])SetAxes(self.controlName,0,0);else SetButton(self.controlName,0);
}
- (void)touchesBegan:(NSSet *)touches withEvent:(UIEvent *)event {
    if(self.owner.editing || self.heldTouch)return;
    self.heldTouch=touches.anyObject;self.pressed=YES;self.generation++;
    if([self isAxis])[self move:self.heldTouch];else self.activationPoll=SetButton(self.controlName,1);
    [self setNeedsDisplay];
}
- (void)touchesMoved:(NSSet *)touches withEvent:(UIEvent *)event {if([touches containsObject:self.heldTouch])[self move:self.heldTouch];}
- (void)touchesEnded:(NSSet *)touches withEvent:(UIEvent *)event {
    if(![touches containsObject:self.heldTouch])return;self.heldTouch=nil;self.pressed=NO;self.stick=CGPointZero;
    if([self.controlName hasSuffix:@"Stick"])SetAxes(self.controlName,0,0);
    else {NSUInteger generation=self.generation;dispatch_after(dispatch_time(DISPATCH_TIME_NOW,50*NSEC_PER_MSEC),dispatch_get_main_queue(),^{[self releaseGeneration:generation attempts:1];});}
    [self setNeedsDisplay];
}
- (void)touchesCancelled:(NSSet *)touches withEvent:(UIEvent *)event {[self cancelInput];}
- (void)cancelInput {self.heldTouch=nil;self.generation++;self.pressed=NO;self.stick=CGPointZero;if([self isAxis])SetAxes(self.controlName,0,0);else SetButton(self.controlName,0);[self setNeedsDisplay];}
- (BOOL)accessibilityActivate {if(self.owner.editing)return NO;if([self isAxis])return NO;SetButton(self.controlName,1);NSUInteger generation=++self.generation;dispatch_after(dispatch_time(DISPATCH_TIME_NOW,150*NSEC_PER_MSEC),dispatch_get_main_queue(),^{if(self.generation==generation)SetButton(self.controlName,0);});return YES;}
@end

@implementation StrayTouchOverlay
- (instancetype)initWithFrame:(CGRect)frame {
    if((self=[super initWithFrame:frame])){
        self.backgroundColor=UIColor.clearColor;self.autoresizingMask=UIViewAutoresizingFlexibleWidth|UIViewAutoresizingFlexibleHeight;
        self.config=[[NSDictionary dictionaryWithContentsOfFile:ConfigPath()] mutableCopy]?:[@{@"preset":@0,@"opacity":@.6,@"scale":@1,@"sensitivity":@1,@"deadzone":@.12,@"shown":@YES,@"positions":@{}} mutableCopy];
        self.sensitivity=MAX(.5,MIN(1.5,[self.config[@"sensitivity"] doubleValue]?:1));self.deadzone=MAX(.05,MIN(.25,[self.config[@"deadzone"] doubleValue]?:.12));
        self.controls=[NSMutableDictionary new];
        for(NSString *name in @[@"A",@"B",@"X",@"Y",@"LeftShoulder",@"RightShoulder",@"LeftTrigger",@"RightTrigger",@"LeftThumb",@"RightThumb",@"Menu",@"View",@"Nexus",@"LeftStick",@"RightStick",@"DPad"]){
            StrayTouchControl *control=[[StrayTouchControl alloc]initWithFrame:CGRectZero];control.controlName=name;control.owner=self;control.accessibilityLabel=name;
            [control addGestureRecognizer:[[UIPanGestureRecognizer alloc]initWithTarget:self action:@selector(controlDragged:)]];
            [control addGestureRecognizer:[[UIPinchGestureRecognizer alloc]initWithTarget:self action:@selector(controlScaled:)]];
            for(UIGestureRecognizer *g in control.gestureRecognizers)g.enabled=NO;
            self.controls[name]=control;[self addSubview:control];
        }
        self.ball=[UIButton buttonWithType:UIButtonTypeSystem];self.ball.backgroundColor=[UIColor colorWithWhite:.08 alpha:.75];self.ball.layer.cornerRadius=22;self.ball.layer.borderWidth=1;self.ball.layer.borderColor=[UIColor colorWithWhite:1 alpha:.5].CGColor;
        [self.ball setTitle:@"🎮" forState:UIControlStateNormal];self.ball.titleLabel.font=[UIFont systemFontOfSize:21];self.ball.accessibilityLabel=@"手柄布局设置";
        [self.ball addTarget:self action:@selector(openSettings) forControlEvents:UIControlEventTouchUpInside];
        [self.ball addGestureRecognizer:[[UIPanGestureRecognizer alloc]initWithTarget:self action:@selector(ballDragged:)]];[self addSubview:self.ball];
        [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(cancelAll) name:UIApplicationWillResignActiveNotification object:nil];
    }return self;
}
- (CGRect)safeRect {CGRect r=UIEdgeInsetsInsetRect(self.bounds,self.safeAreaInsets);return CGRectInset(r,8,8);}
- (void)layoutSubviews {
    [super layoutSubviews];CGRect safe=[self safeRect];CGFloat w=safe.size.width,h=safe.size.height;BOOL compact=[self.config[@"preset"] integerValue]==1;
    CGFloat unit=MIN(1,h/360),scale=MAX(.7,MIN(1.4,[self.config[@"scale"] doubleValue]?:1));
    // Coordinates are relative to the safe area and survive resolution changes.
    NSDictionary *defaults=@{@"LeftTrigger":@[@.065,@.13,@66,@36],@"LeftShoulder":@[@.065,@.26,@66,@36],@"RightTrigger":@[@.935,@.13,@66,@36],@"RightShoulder":@[@.935,@.26,@66,@36],
        @"A":@[@.905,@.81,@48,@48],@"B":@[@.953,@.69,@48,@48],@"X":@[@.857,@.69,@48,@48],@"Y":@[@.905,@.57,@48,@48],
        @"LeftThumb":@[@.285,@.88,@38,@38],@"RightThumb":@[@.71,@.9,@38,@38],
        @"LeftStick":@[@(compact?.135:.21),@.57,@104,@104],@"RightStick":@[@(compact?.745:.74),@.64,@104,@104],@"DPad":@[@(compact?.29:.08),@.79,@88,@88],
        @"View":@[@.43,@.94,@34,@34],@"Nexus":@[@.50,@.94,@34,@34],@"Menu":@[@.57,@.94,@34,@34]};
    NSDictionary *positions=self.config[@"positions"];
    for(NSString *name in self.controls){StrayTouchControl *c=self.controls[name];NSArray *v=positions[name]?:defaults[name];CGFloat bw=[v[2] doubleValue]*unit*scale,bh=[v[3] doubleValue]*unit*scale;
        bw=MAX(28,MIN(w,bw));bh=MAX(28,MIN(h,bh));CGFloat x=safe.origin.x+w*[v[0] doubleValue],y=safe.origin.y+h*[v[1] doubleValue];
        c.frame=CGRectMake(MAX(safe.origin.x,MIN(CGRectGetMaxX(safe)-bw,x-bw/2)),MAX(safe.origin.y,MIN(CGRectGetMaxY(safe)-bh,y-bh/2)),bw,bh);
        c.hidden=![self.config[@"shown"] boolValue] && !self.editing;c.alpha=MAX(.25,MIN(.95,[self.config[@"opacity"] doubleValue]?:.6));[c setNeedsDisplay];
    }
    NSArray *ball=self.config[@"ball"]?:@[@.5,@.09];CGFloat bx=safe.origin.x+w*[ball[0] doubleValue],by=safe.origin.y+h*[ball[1] doubleValue];
    self.ball.frame=CGRectMake(MAX(safe.origin.x,MIN(CGRectGetMaxX(safe)-44,bx-22)),MAX(safe.origin.y,MIN(CGRectGetMaxY(safe)-44,by-22)),44,44);
    if(self.panel){CGFloat width=MIN(420,w),height=MIN(350,h);self.panel.frame=CGRectMake(CGRectGetMidX(safe)-width/2,CGRectGetMidY(safe)-height/2,width,height);}
}
- (BOOL)pointInside:(CGPoint)p withEvent:(UIEvent *)event {if(self.panel)return YES;for(UIView *v in self.subviews)if(!v.hidden && CGRectContainsPoint(v.frame,p))return YES;return NO;}
- (void)save {[self.config writeToFile:ConfigPath() atomically:YES];Report();}
- (void)cancelAll {for(StrayTouchControl *c in self.controls.allValues)[c cancelInput];ResetState();}
- (void)recordPosition:(StrayTouchControl *)control {
    CGRect r=[self safeRect];CGFloat unit=MIN(1,r.size.height/360),scale=[self.config[@"scale"] doubleValue]?:1;
    NSMutableDictionary *positions=[self.config[@"positions"] mutableCopy]?:[NSMutableDictionary new];
    positions[control.controlName]=@[@((control.center.x-r.origin.x)/r.size.width),@((control.center.y-r.origin.y)/r.size.height),@(control.bounds.size.width/(unit*scale)),@(control.bounds.size.height/(unit*scale))];self.config[@"positions"]=positions;
}
- (void)controlDragged:(UIPanGestureRecognizer *)gesture {
    StrayTouchControl *c=(id)gesture.view;CGPoint delta=[gesture translationInView:self];CGRect r=[self safeRect];
    c.center=CGPointMake(MAX(r.origin.x+c.bounds.size.width/2,MIN(CGRectGetMaxX(r)-c.bounds.size.width/2,c.center.x+delta.x)),MAX(r.origin.y+c.bounds.size.height/2,MIN(CGRectGetMaxY(r)-c.bounds.size.height/2,c.center.y+delta.y)));
    [gesture setTranslation:CGPointZero inView:self];[self recordPosition:c];if(gesture.state==UIGestureRecognizerStateEnded)[self save];
}
- (void)controlScaled:(UIPinchGestureRecognizer *)gesture {StrayTouchControl *c=(id)gesture.view;CGFloat width=MAX(28,MIN(160,c.bounds.size.width*gesture.scale)),height=MAX(28,MIN(160,c.bounds.size.height*gesture.scale));c.bounds=CGRectMake(0,0,width,height);gesture.scale=1;[self recordPosition:c];if(gesture.state==UIGestureRecognizerStateEnded){[self save];[self setNeedsLayout];}}
- (void)ballDragged:(UIPanGestureRecognizer *)gesture {CGPoint d=[gesture translationInView:self];CGRect r=[self safeRect];self.ball.center=CGPointMake(MAX(r.origin.x+22,MIN(CGRectGetMaxX(r)-22,self.ball.center.x+d.x)),MAX(r.origin.y+22,MIN(CGRectGetMaxY(r)-22,self.ball.center.y+d.y)));[gesture setTranslation:CGPointZero inView:self];self.config[@"ball"]=@[@((self.ball.center.x-r.origin.x)/r.size.width),@((self.ball.center.y-r.origin.y)/r.size.height)];if(gesture.state==UIGestureRecognizerStateEnded)[self save];}
- (void)closeSettings {[self.panel removeFromSuperview];self.panel=nil;[self.canvas becomeFirstResponder];[self setNeedsLayout];}
- (void)setEditingLayout:(BOOL)editing {[self cancelAll];self.editing=editing;for(StrayTouchControl *c in self.controls.allValues){for(UIGestureRecognizer *g in c.gestureRecognizers)g.enabled=editing;[c setNeedsDisplay];}[self.ball setTitle:editing?@"完成":@"🎮" forState:UIControlStateNormal];self.ball.titleLabel.font=[UIFont systemFontOfSize:editing?13:21];[self setNeedsLayout];}
- (void)editLayout {[self closeSettings];[self setEditingLayout:YES];}
- (void)changePreset:(UISegmentedControl *)sender {[self cancelAll];self.config[@"preset"]=@(sender.selectedSegmentIndex);self.config[@"positions"]=@{};[self save];[self setNeedsLayout];}
- (void)visibility:(UISwitch *)sender {[self cancelAll];self.config[@"shown"]=@(sender.on);BOOL was=atomic_exchange(&ControllerEnabled,sender.on);if(was!=sender.on)[NSNotificationCenter.defaultCenter postNotificationName:sender.on?GCControllerDidConnectNotification:GCControllerDidDisconnectNotification object:TouchController];[self save];[self setNeedsLayout];}
- (void)sliderChanged:(UISlider *)sender {NSArray *keys=@[@"opacity",@"scale",@"sensitivity",@"deadzone"];self.config[keys[sender.tag]]=@(sender.value);self.sensitivity=[self.config[@"sensitivity"] doubleValue];self.deadzone=[self.config[@"deadzone"] doubleValue];[self save];[self setNeedsLayout];}
- (void)resetLayout {[self cancelAll];self.config[@"positions"]=@{};self.config[@"ball"]=@[@.5,@.09];self.config[@"scale"]=@1;self.config[@"opacity"]=@.6;self.config[@"sensitivity"]=@1;self.config[@"deadzone"]=@.12;self.sensitivity=1;self.deadzone=.12;[self save];[self closeSettings];[self openSettings];}
- (void)openSettings {
    if(self.editing){[self setEditingLayout:NO];[self save];return;}
    if(self.panel){[self closeSettings];return;}[self cancelAll];
    self.panel=[UIView new];self.panel.backgroundColor=[UIColor colorWithWhite:.07 alpha:.96];self.panel.layer.cornerRadius=18;[self addSubview:self.panel];[self layoutIfNeeded];[self setNeedsLayout];[self layoutIfNeeded];
    UIScrollView *scroll=[[UIScrollView alloc]initWithFrame:CGRectInset(self.panel.bounds,16,12)];scroll.autoresizingMask=UIViewAutoresizingFlexibleWidth|UIViewAutoresizingFlexibleHeight;[self.panel addSubview:scroll];
    UIStackView *stack=[[UIStackView alloc]initWithFrame:CGRectMake(0,0,scroll.bounds.size.width,430)];stack.axis=UILayoutConstraintAxisVertical;stack.spacing=10;stack.distribution=UIStackViewDistributionFillEqually;stack.autoresizingMask=UIViewAutoresizingFlexibleWidth;[scroll addSubview:stack];scroll.contentSize=stack.bounds.size;
    UILabel *title=[UILabel new];title.text=@"触屏手柄 · Xbox 布局";title.textColor=UIColor.whiteColor;title.font=[UIFont boldSystemFontOfSize:18];[stack addArrangedSubview:title];
    UISegmentedControl *presets=[[UISegmentedControl alloc]initWithItems:@[@"经典",@"紧凑"]];presets.selectedSegmentIndex=[self.config[@"preset"] integerValue];[presets addTarget:self action:@selector(changePreset:) forControlEvents:UIControlEventValueChanged];[stack addArrangedSubview:presets];
    UIStackView *visible=[UIStackView new];UILabel *label=[UILabel new];label.text=@"显示触屏手柄";label.textColor=UIColor.whiteColor;[visible addArrangedSubview:label];UISwitch *toggle=[UISwitch new];toggle.on=[self.config[@"shown"] boolValue];[toggle addTarget:self action:@selector(visibility:) forControlEvents:UIControlEventValueChanged];[visible addArrangedSubview:toggle];[stack addArrangedSubview:visible];
    NSArray *titles=@[@"透明度",@"按钮大小",@"摇杆灵敏度",@"摇杆死区"];
    NSArray *keys=@[@"opacity",@"scale",@"sensitivity",@"deadzone"];
    NSArray *ranges=@[@[@.25,@.95],@[@.7,@1.4],@[@.5,@1.5],@[@.05,@.25]];
    for(NSUInteger i=0;i<4;i++){UIStackView *row=[UIStackView new];row.spacing=12;UILabel *l=[UILabel new];l.text=titles[i];l.textColor=UIColor.whiteColor;l.font=[UIFont systemFontOfSize:14];[l.widthAnchor constraintEqualToConstant:95].active=YES;[row addArrangedSubview:l];UISlider *s=[UISlider new];s.minimumValue=[ranges[i][0] floatValue];s.maximumValue=[ranges[i][1] floatValue];s.value=[self.config[keys[i]] floatValue];s.tag=i;s.accessibilityLabel=titles[i];[s addTarget:self action:@selector(sliderChanged:) forControlEvents:UIControlEventValueChanged];[row addArrangedSubview:s];[stack addArrangedSubview:row];}
    for(NSArray *item in @[@[@"编辑位置：拖动 / 双指缩放",NSStringFromSelector(@selector(editLayout))],@[@"恢复当前布局",NSStringFromSelector(@selector(resetLayout))],@[@"返回游戏",NSStringFromSelector(@selector(closeSettings))]]){UIButton *button=[UIButton buttonWithType:UIButtonTypeSystem];[button setTitle:item[0] forState:UIControlStateNormal];[button addTarget:self action:NSSelectorFromString(item[1]) forControlEvents:UIControlEventTouchUpInside];[stack addArrangedSubview:button];}
}
@end

void StrayInstallTouchGamepad(void){
    static dispatch_once_t once;dispatch_once(&once,^{
        StateLock=[NSObject new];LastInputs=[NSMutableDictionary new];TouchController=[GCController controllerWithExtendedGamepad];TouchController.playerIndex=(GCControllerPlayerIndex)0;
        NSDictionary *config=[NSDictionary dictionaryWithContentsOfFile:ConfigPath()];atomic_store(&ControllerEnabled,config[@"shown"]?[config[@"shown"] boolValue]:YES);
        Class meta=object_getClass(GCController.class);Method list=class_getClassMethod(GCController.class,@selector(controllers));OriginalControllers=(void *)method_getImplementation(list);class_replaceMethod(meta,@selector(controllers),(IMP)Controllers,method_getTypeEncoding(list));
        Class cls=object_getClass(TouchController);Method capture=class_getInstanceMethod(cls,@selector(capture));OriginalCapture=(void *)method_getImplementation(capture);class_replaceMethod(cls,@selector(capture),(IMP)Capture,method_getTypeEncoding(capture));
        Method category=class_getInstanceMethod(cls,@selector(productCategory));OriginalCategory=(void *)method_getImplementation(category);class_replaceMethod(cls,@selector(productCategory),(IMP)TouchCategory,method_getTypeEncoding(category));
        GCExtendedGamepad *g=TouchController.extendedGamepad;
        fprintf(stderr,"STRAY_TOUCH_CONTROLLER installed=1 snapshot=%d menu=%d view=%d home=%d l3=%d r3=%d\n",TouchController.isSnapshot,g.buttonMenu!=nil,g.buttonOptions!=nil,g.buttonHome!=nil,g.leftThumbstickButton!=nil,g.rightThumbstickButton!=nil);Report();
    });
}
void StrayAttachTouchGamepad(UIWindow *window,UIView *canvas){
    StrayInstallTouchGamepad();UIView *root=window.rootViewController.view;
    for(UIView *v in root.subviews)if([v isKindOfClass:StrayTouchOverlay.class]){((StrayTouchOverlay *)v).canvas=canvas;[root bringSubviewToFront:v];return;}
    StrayTouchOverlay *overlay=[[StrayTouchOverlay alloc]initWithFrame:root.bounds];overlay.canvas=canvas;[root addSubview:overlay];
    fprintf(stderr,"STRAY_TOUCH_OVERLAY attached=1 controls=%lu\n",(unsigned long)overlay.controls.count);
}
