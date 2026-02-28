#include "bindings.h"

#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#import <WebKit/WebKit.h>

#include "AppViewController.h"

struct RenderState2
{
    id<MTLBuffer> quadInstanceBuffer;
    id<MTLBuffer> quadUniformBuffer;
    id<MTLRenderPipelineState> quadPipelineState;
};

void iosLog(const char* string)
{
    NSLog(@"%@", @(string));
}

struct Slice getResourcePath(void)
{
    // TODO this probably leaks memory
    NSString* resourcePath = [[NSBundle mainBundle] resourcePath];
    NSData* data = [resourcePath dataUsingEncoding:NSUTF8StringEncoding];
    struct Slice slice = {
        .size = [data length],
        .data = (uint8_t*)[data bytes],
    };
    return slice;
}

struct Slice getWriteDirPath(void)
{
    // TODO this probably leaks memory
    NSArray* paths = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES);
    NSString* documentsDir = [paths objectAtIndex:0];
    NSData* documentsDirUtf8 = [documentsDir dataUsingEncoding:NSUTF8StringEncoding];
    struct Slice slice = {
        .size = [documentsDirUtf8 length],
        .data = (uint8_t*)[documentsDirUtf8 bytes],
    };
    return slice;
}

struct Buffer* createBuffer(void* context, uint64_t length)
{
    AppViewController* controller = (AppViewController*)context;
    id<MTLBuffer> buffer = [
        controller.device
        newBufferWithLength:length
        options:MTLResourceCPUCacheModeDefaultCache
    ];
    if (buffer == nil) {
        return nil;
    }
    return (struct Buffer*)buffer;
}

id<MTLTexture> createAndLoadTextureMetal(id<MTLDevice> device, uint32_t width, uint32_t height, MTLPixelFormat pixelFormat, const void* data)
{
    MTLTextureDescriptor* textureDescriptor = [[MTLTextureDescriptor alloc] init];
    uint32_t channels = 4;
    switch (pixelFormat) {
    case MTLPixelFormatR8Unorm: {
        channels = 1;
    } break;
    case MTLPixelFormatRGBA8Unorm: {
    } break;
    case MTLPixelFormatBGRA8Unorm: {
    } break;
    default: {
    } break;
    }
    textureDescriptor.pixelFormat = pixelFormat;
    textureDescriptor.width = width;
    textureDescriptor.height = height;
    id<MTLTexture> texture = [device newTextureWithDescriptor:textureDescriptor];
    if (texture == nil) {
        return nil;
    }

    const MTLRegion region = {
        { 0, 0, 0 },
        {width, height, 1}
    };
    [texture replaceRegion:region
               mipmapLevel:0
                 withBytes:data
               bytesPerRow:width * channels];
    return texture;
}

struct Texture* createAndLoadTexture(void* context, uint32_t width, uint32_t height, enum TextureFormat format, const void* data)
{
    AppViewController* controller = (AppViewController*)context;
    MTLPixelFormat pixelFormat;
    switch (format) {
    case R8: {
        pixelFormat = MTLPixelFormatR8Unorm;
    } break;
    case RGBA8: {
        pixelFormat = MTLPixelFormatRGBA8Unorm;
    } break;
    case BGRA8: {
        pixelFormat = MTLPixelFormatBGRA8Unorm;
    } break;
    }
    id<MTLTexture> texture = createAndLoadTextureMetal(controller.device, width, height, pixelFormat, data);
    return (struct Texture*)texture;
}

struct RenderState2* createRenderState(void* context)
{
    AppViewController* controller = (AppViewController*)context;

    // Quads
    id<MTLBuffer> quadInstanceBuffer;
    id<MTLBuffer> quadUniformBuffer;
    id<MTLRenderPipelineState> quadPipelineState;
    {
        quadInstanceBuffer = [
            controller.device
            newBufferWithLength:sizeof(struct QuadInstanceData) * MAX_QUADS
            options:MTLResourceCPUCacheModeDefaultCache
        ];
        if (quadInstanceBuffer == nil) {
            NSLog(@"ZIG.m error creating quad instance buffer");
            return nil;
        }

        quadUniformBuffer = [
            controller.device
            newBufferWithLength:sizeof(struct QuadUniforms)
            options:MTLResourceCPUCacheModeDefaultCache
        ];
        if (quadUniformBuffer == nil) {
            NSLog(@"ZIG.m error creating quad uniform buffer");
            return nil;
        }

        MTLRenderPipelineDescriptor* renderPipelineDescriptor = [[MTLRenderPipelineDescriptor alloc] init];
        renderPipelineDescriptor.vertexFunction = [controller.library newFunctionWithName:@"quadVertMain"];
        renderPipelineDescriptor.fragmentFunction = [controller.library newFunctionWithName:@"quadFragMain"];
        MTLRenderPipelineColorAttachmentDescriptor* attachment = renderPipelineDescriptor.colorAttachments[0];
        attachment.pixelFormat = controller.metalLayer.pixelFormat;
        attachment.blendingEnabled = YES;
        attachment.rgbBlendOperation = MTLBlendOperationAdd;
        attachment.alphaBlendOperation = MTLBlendOperationAdd;
        attachment.sourceRGBBlendFactor = MTLBlendFactorSourceAlpha;
        attachment.destinationRGBBlendFactor = MTLBlendFactorOneMinusSourceAlpha;
        attachment.sourceAlphaBlendFactor = MTLBlendFactorOne;
        attachment.destinationAlphaBlendFactor = MTLBlendFactorOne;

        NSError* error;
        quadPipelineState = [
            controller.device
            newRenderPipelineStateWithDescriptor:renderPipelineDescriptor
            error:&error
        ];
        if (quadPipelineState == nil) {
            NSLog(@"ZIG.m error creating quad render pipeline state: %@", error);
            return nil;
        }
    }

    struct RenderState2* renderState = (struct RenderState2*)malloc(sizeof(struct RenderState2));
    if (renderState == NULL) {
        NSLog(@"ZIG.m Failed to allocate RenderState2");
        return nil;
    }
    renderState->quadInstanceBuffer = quadInstanceBuffer;
    renderState->quadUniformBuffer = quadUniformBuffer;
    renderState->quadPipelineState = quadPipelineState;

    return renderState;
}

void renderQuads(void* context, const struct RenderState2* renderState, size_t instances, size_t bufferDataLength, const void* bufferData, size_t numTextureIds, const uint64_t* textureIds, float screenWidth, float screenHeight)
{
    AppViewController* controller = (AppViewController*)context;
    if (controller.renderCommandEncoder == nil) {
        NSLog(@"renderRect called outside of frame draw");
        return;
    }

    memcpy([renderState->quadInstanceBuffer contents], bufferData, bufferDataLength);
    const struct QuadUniforms uniforms = {
        .screenSize = {
            .x = screenWidth,
            .y = screenHeight,
        },
    };
    memcpy([renderState->quadUniformBuffer contents], &uniforms, sizeof(struct QuadUniforms));

    const id<MTLRenderCommandEncoder> encoder = controller.renderCommandEncoder;
    [encoder setRenderPipelineState:renderState->quadPipelineState];
    [encoder setVertexBuffer:renderState->quadInstanceBuffer offset:0 atIndex:0];
    [encoder setVertexBuffer:renderState->quadUniformBuffer offset:0 atIndex:1];
    for (size_t i = 0; i < numTextureIds; i++) {
        [encoder setFragmentTexture:(id<MTLTexture>)textureIds[i] atIndex:i];
    }
    [encoder drawPrimitives:MTLPrimitiveTypeTriangle
                vertexStart:0
                vertexCount:6
              instanceCount:instances];
}

void setKeyboardVisible(void* context, int visible)
{
    AppViewController* controller = (AppViewController*)context;

    if (visible != 0) {
        if (controller.dummyTextView == nil) {
            CGRect rect;
            rect.origin.x = 0;
            rect.origin.y = 0;
            rect.size.width = 0;
            rect.size.height = 0;
            controller.dummyTextView = [[DummyTextView alloc] initWithFrame:rect];
            controller.dummyTextView.controller = controller;
            [controller.view addSubview:controller.dummyTextView];
        }
        [controller.dummyTextView becomeFirstResponder];
    } else if (visible == 0 && controller.dummyTextView != nil) {
        [controller.dummyTextView resignFirstResponder];
        [controller.dummyTextView removeFromSuperview];
        [controller.dummyTextView release];
        controller.dummyTextView = nil;
    }
}

void httpRequest(void* context, enum HttpMethod method, struct Slice url, struct Slice h1, struct Slice v1, struct Slice body)
{
    AppViewController* controller = (AppViewController*)context;
    const struct Slice nullSlice = {
        .size = 0,
        .data = NULL,
    };

    NSURLSessionConfiguration* conf = [NSURLSessionConfiguration defaultSessionConfiguration];
    NSURLSession* session = [NSURLSession sessionWithConfiguration:conf];

    @try {
        // Create NSURL object for request.
        NSString* urlString = [[NSString alloc] initWithBytes:url.data length:url.size encoding:NSUTF8StringEncoding];
        NSURL* nsUrl = [NSURL URLWithString:urlString];

        // Create the request object.
        NSMutableURLRequest* request = [[NSMutableURLRequest alloc] init];
        [request setURL:nsUrl];
        if (method == HTTP_GET) {
            [request setHTTPMethod:@"GET"];
        } else if (method == HTTP_POST) {
            [request setHTTPMethod:@"POST"];
        } else {
            onHttp(controller.data, method, url, 0, nullSlice);
            return;
        }
        if (h1.size > 0) {
            NSString* h1String = [[NSString alloc] initWithBytes:h1.data length:h1.size encoding:NSUTF8StringEncoding];
            NSString* v1String = [[NSString alloc] initWithBytes:v1.data length:v1.size encoding:NSUTF8StringEncoding];
            [request setValue:v1String forHTTPHeaderField:h1String];
        }
        if (body.size > 0) {
            NSData* postData = [NSData dataWithBytes:body.data length:body.size];
            NSString* contentLengthString = [NSString stringWithFormat:@"%zu", body.size];
            [request setValue:contentLengthString forHTTPHeaderField:@"Content-Length"];
            [request setHTTPBody:postData];
        }

        // Send the request.
        NSURLSessionDataTask* task = [session dataTaskWithRequest:request completionHandler:^(NSData* data, NSURLResponse* response, NSError* error) {
            // Handle the response in a callback.
            const NSHTTPURLResponse* httpResponse = (const NSHTTPURLResponse*)response;
            NSData* urlStringUtf8 = [urlString dataUsingEncoding:NSUTF8StringEncoding];
            const struct Slice urlSlice = {
                .size = urlStringUtf8.length,
                .data = (uint8_t*)urlStringUtf8.bytes,
            };
            const struct Slice responseBodySlice = {
                .size = data.length,
                .data = (uint8_t*)data.bytes,
            };
            onHttp(controller.data, method, urlSlice, [httpResponse statusCode], responseBodySlice);
        }];
        [task resume];
    } @catch (id exception) {
        NSLog(@"ZIG.m httpRequest exception %@", exception);
        onHttp(controller.data, method, url, 0, nullSlice);
    }
}

uint32_t getStatusBarHeight(void* context)
{
    AppViewController* controller = (AppViewController*)context;

    const UIScreen* screen = [UIScreen mainScreen];
    const CGFloat height = controller.view.window.windowScene.statusBarManager.statusBarFrame.size.height;
    const CGFloat heightPixels = height * screen.nativeScale;
    return (uint32_t)heightPixels;
}

int openDocumentReader(void* context, struct Slice path, uint32_t marginTop, uint32_t marginBottom)
{
    AppViewController* controller = (AppViewController*)context;

    NSString* pathString = [[NSString alloc] initWithBytes:path.data length:path.size encoding:NSUTF8StringEncoding];
    if (pathString == nil) {
        NSLog(@"ZIG.m openDocumentReader pathString nil");
        return 0;
    }
    NSURL* url = [NSURL fileURLWithPath:pathString];
    if (url == nil) {
        NSLog(@"ZIG.m openDocumentReader url nil");
        return 0;
    }

    if (controller.webView == nil) {
        const UIScreen* screen = [UIScreen mainScreen];
        const CGRect screenBounds = [screen bounds];
        const double marginTopS = (double)marginTop / screen.nativeScale;
        const double marginBottomS = (double)marginBottom / screen.nativeScale;
        const CGRect bounds = {
            .origin = {0, marginTopS},
            .size = {
                screenBounds.size.width,
                screenBounds.size.height - marginTopS - marginBottomS
            },
        };

        WKWebViewConfiguration* configuration = [[WKWebViewConfiguration alloc] init];
        controller.webView = [[WKWebView alloc] initWithFrame:bounds configuration:configuration];
        if (controller.webView == nil) {
            NSLog(@"ZIG.m WKWebView null");
            return 0;
        }

        [controller.view addSubview:controller.webView];
    }

    [controller.webView loadFileURL:url allowingReadAccessToURL:url];
    [controller.webView becomeFirstResponder];

    return 1;
}

void closeDocumentReader(void* context)
{
    AppViewController* controller = (AppViewController*)context;
    if (controller.webView != nil) {
        [controller.webView resignFirstResponder];
        [controller.webView removeFromSuperview];
        [controller.webView release];
        controller.webView = nil;
    }
}

void openUrl(void* context, struct Slice url)
{
    NSString* urlString = [[NSString alloc] initWithBytes:url.data length:url.size encoding:NSUTF8StringEncoding];
    if (urlString == nil) {
        return;
    }
    [[UIApplication sharedApplication] openURL:[NSURL URLWithString:urlString]
                                       options:nil
                                       completionHandler:nil];
}

void setClipboardContents(void* context, struct Slice string)
{
    NSString* nsString = [[NSString alloc] initWithBytes:string.data length:string.size encoding:NSUTF8StringEncoding];
    if (nsString == nil) {
        return;
    }
    [[UIPasteboard generalPasteboard] setString:nsString];
}
