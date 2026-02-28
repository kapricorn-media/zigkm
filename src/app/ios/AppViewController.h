#pragma once

#import <Metal/Metal.h>
#import <UIKit/UIKit.h>
#import <WebKit/WebKit.h>

@class DummyTextView;

@interface AppViewController : UIViewController
@property(assign) id<MTLDevice> device;
@property(assign) CAMetalLayer* metalLayer;
@property(assign) id<MTLLibrary> library;
@property(assign) id<MTLRenderCommandEncoder> renderCommandEncoder;
@property(assign) DummyTextView* dummyTextView;
@property(assign) WKWebView* webView;
@property(assign) void* data;
@end

@interface DummyTextView : UIView<UIKeyInput>
@property(assign) AppViewController* controller;
@end
