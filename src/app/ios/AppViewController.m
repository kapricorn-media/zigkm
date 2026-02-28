#import "AppViewController.h"

#import <GLKit/GLKMath.h>
#import <QuartzCore/CAMetalLayer.h>
#import <simd/simd.h>

#import "bindings.h"

enum { TEXT_BUF_LENGTH = 64 * 1024 };
enum { TOUCH_EVENTS_BUF_LENGTH = 1024 };

enum TouchType toTouchType(UITouchType type)
{
    switch (type) {
    case UITouchTypeDirect:
        return TOUCH_TYPE_DIRECT;
    case UITouchTypeIndirect:
    case UITouchTypePencil:
    case UITouchTypeIndirectPointer:
        return TOUCH_TYPE_UNSUPPORTED;
    }

    return TOUCH_TYPE_UNKNOWN;
}

enum TouchPhase toTouchPhase(UITouchPhase phase)
{
    switch (phase) {
    case UITouchPhaseBegan:
        return TOUCH_PHASE_BEGIN;
    case UITouchPhaseStationary:
        return TOUCH_PHASE_STATIONARY;
    case UITouchPhaseMoved:
        return TOUCH_PHASE_MOVE;
    case UITouchPhaseEnded:
        return TOUCH_PHASE_END;
    case UITouchPhaseCancelled:
        return TOUCH_PHASE_CANCEL;
    case UITouchPhaseRegionEntered:
    case UITouchPhaseRegionMoved:
    case UITouchPhaseRegionExited:
        return TOUCH_PHASE_UNSUPPORTED;
    }

    return TOUCH_PHASE_UNKNOWN;
}

int processTouches(NSSet<UITouch*>* touches, struct TouchEvent* outTouchEvents)
{
    const UIScreen* screen = [UIScreen mainScreen];
    const CGRect nativeBounds = [screen nativeBounds];
    const double nativeScale = screen.nativeScale;

    int i = 0;
    for (UITouch* touch in touches) {
        if (i >= TOUCH_EVENTS_BUF_LENGTH) {
            // TODO lost touch events
            break;
        }

        const CGPoint loc = [touch locationInView:nil];
        outTouchEvents[i].id = touch.hash;
        outTouchEvents[i].x = (uint32_t)round(loc.x * nativeScale);
        outTouchEvents[i].y = (uint32_t)round(nativeBounds.size.height - loc.y * nativeScale);
        outTouchEvents[i].tapCount = touch.tapCount;
        outTouchEvents[i].type = toTouchType(touch.type);
        outTouchEvents[i].phase = toTouchPhase(touch.phase);

        i += 1;
    }

    return i;
}

@implementation DummyTextView
{
    uint32_t buf[TEXT_BUF_LENGTH];
}

- (BOOL)canBecomeFirstResponder
{
    return YES;
}

- (BOOL)canResignFirstResponder
{
    return YES;
}

- (BOOL)hasText
{
    return NO;
}

- (void)insertText:(NSString *)text
{
    NSUInteger byteLength;
    NSRange range;
    range.length = text.length;
    range.location = 0;
    [text getBytes:buf
         maxLength:TEXT_BUF_LENGTH
        usedLength:&byteLength
          encoding:NSUTF32StringEncoding
           options:0
             range:range
    remainingRange:nil];

    if (byteLength % 4 != 0) {
        // TODO bad!
    }
    const uint32_t utf32Length = byteLength / 4;
    onTextUtf32(self.controller.data, utf32Length, buf);
}

- (void)deleteBackward
{
    buf[0] = 8; // ASCII backspace
    onTextUtf32(self.controller.data, 1, buf);
}

@end

@implementation AppViewController
{
    id<MTLCommandQueue> commandQueue;
    id<MTLDepthStencilState> depthStencilState;
    CADisplayLink* displayLink;
    struct TouchEvent touchEvents[TOUCH_EVENTS_BUF_LENGTH];
}

+ (Class)layerClass
{
    return [CAMetalLayer class];
}

- (void)viewDidLoad
{
    [super viewDidLoad];
    NSLog(@"ZIG.m viewDidLoad");

    const UIScreen* screen = [UIScreen mainScreen];
    const CGRect bounds = [screen bounds];
    const CGRect nativeBounds = [screen nativeBounds];
    const double nativeScale = screen.nativeScale;
    NSLog(@"ZIG.m outside bounds %f x %f", bounds.size.width, bounds.size.height);
    NSLog(@"ZIG.m nativeBounds %f x %f", nativeBounds.size.width, nativeBounds.size.height);
    NSLog(@"ZIG.m nativeScale %f", nativeScale);

    self.device = MTLCreateSystemDefaultDevice();
    if (self.device == NULL) {
        NSLog(@"ZIG.m MTLCreateSystemDefaultDevice failed");
        // TODO what now?
        return;
    }

    self.metalLayer = [CAMetalLayer layer];
    self.metalLayer.device = self.device;
    self.metalLayer.pixelFormat = MTLPixelFormatBGRA8Unorm;
    self.metalLayer.framebufferOnly = YES;
    self.metalLayer.drawableSize = nativeBounds.size;
    self.metalLayer.frame = bounds;

    [self.view.layer addSublayer:self.metalLayer];
    [self.view setOpaque:YES];
    [self.view setBackgroundColor:nil];
    [self.view setContentScaleFactor:nativeScale];
    [self.view setMultipleTouchEnabled:YES];

    self.library = [self.device newDefaultLibrary];

    commandQueue = [self.device newCommandQueue];

    MTLDepthStencilDescriptor* depthStencilDescriptor = [MTLDepthStencilDescriptor new];
    depthStencilDescriptor.depthCompareFunction = MTLCompareFunctionLessEqual;
    depthStencilDescriptor.depthWriteEnabled = YES;
    depthStencilState = [self.device newDepthStencilStateWithDescriptor:depthStencilDescriptor];

    displayLink = [CADisplayLink displayLinkWithTarget:self selector:@selector(renderScene)];
    [displayLink addToRunLoop:[NSRunLoop currentRunLoop] forMode:NSDefaultRunLoopMode];

    self.dummyTextView = nil;
    self.webView = nil;
    self.data = onStart(self, nativeBounds.size.width, nativeBounds.size.height, nativeScale);
    if (self.data == NULL) {
        NSLog(@"ZIG.m onStart failed");
        // TODO what now?
    }
}

- (void)renderScene
{
    const UIScreen* screen = [UIScreen mainScreen];
    const CGRect nativeBounds = [screen nativeBounds];

    id<CAMetalDrawable> frameDrawable = [self.metalLayer nextDrawable];
    MTLRenderPassDescriptor* renderPassDescriptor = [[MTLRenderPassDescriptor alloc] init];
    renderPassDescriptor.colorAttachments[0].texture = frameDrawable.texture;
    renderPassDescriptor.colorAttachments[0].loadAction = MTLLoadActionClear;
    renderPassDescriptor.colorAttachments[0].clearColor = MTLClearColorMake(0.0, 0.0, 0.0, 0.0);
    renderPassDescriptor.colorAttachments[0].storeAction = MTLStoreActionStore;

    id<MTLCommandBuffer> commandBuffer = [commandQueue commandBuffer];
    self.renderCommandEncoder = [commandBuffer renderCommandEncoderWithDescriptor:renderPassDescriptor];
    const MTLViewport viewport = {
        0.0, 0.0, nativeBounds.size.width, nativeBounds.size.height, 0.0, 1.0
    };
    [self.renderCommandEncoder setViewport:viewport];
    [self.renderCommandEncoder setDepthStencilState:depthStencilState];
    [self.renderCommandEncoder setFrontFacingWinding:MTLWindingCounterClockwise];
    [self.renderCommandEncoder setCullMode:MTLCullModeBack];

    int shouldDraw = 0;
    if (self.data != NULL) {
        shouldDraw = updateAndRender(self, self.data, nativeBounds.size.width, nativeBounds.size.height);
    }

    [self.renderCommandEncoder endEncoding];

    if (shouldDraw != 0) {
        [commandBuffer presentDrawable:frameDrawable];
        [commandBuffer commit];
    }

    self.renderCommandEncoder = nil;
}

- (void)dealloc
{
    [displayLink invalidate];
    commandQueue = nil;
    _device = nil;
    [super dealloc];
}

- (void)drawableResize:(CGSize)size
{
    NSLog(@"ZIG.m drawableResize: %f x %f", size.width, size.height);
}

- (void)renderToMetalLayer:(nonnull CAMetalLayer *)layer
{
}

- (void)touchesBegan:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event
{
    const int numTouches = processTouches(touches, touchEvents);
    onTouchEvents(self.data, numTouches, touchEvents);
}

- (void)touchesMoved:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event
{
    const int numTouches = processTouches(touches, touchEvents);
    onTouchEvents(self.data, numTouches, touchEvents);
}

- (void)touchesEnded:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event
{
    const int numTouches = processTouches(touches, touchEvents);
    onTouchEvents(self.data, numTouches, touchEvents);
}

- (void)touchesCancelled:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event
{
    const int numTouches = processTouches(touches, touchEvents);
    onTouchEvents(self.data, numTouches, touchEvents);
}

@end
