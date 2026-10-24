// Non-GUI Metal/CA contract test: no NSApplication or NSWindow is created.
#import <AppKit/AppKit.h>
#import <QuartzCore/CAMetalLayer.h>
#import <Metal/Metal.h>
#import <QuartzCore/CATransaction.h>
#import <QuartzCore/CAAnimation.h>
#import <objc/runtime.h>
#include <assert.h>
#include <math.h>
#include <stdint.h>
#include <stdio.h>
static unsigned renderCopies;
void metal_command_buffer_note_engine(void *command, int engine) { (void)command; assert(engine == 0); renderCopies++; }
@interface ZenitFullscreenHeaderHost : NSObject
@property(nonatomic,strong) NSView *header;
@property(nonatomic) BOOL pendingFullscreen, exiting, active;
@property(nonatomic) NSUInteger presentationEpoch;
@end
@implementation ZenitFullscreenHeaderHost
@end
@interface WindowWrapper : NSObject
@property(nonatomic,strong) NSWindow *window;
@property(nonatomic,strong) NSView *metalView;
@property(nonatomic) uint64_t chromeStateGeneration;
@property(nonatomic) BOOL chromeFullscreenTransition;
@property(nonatomic,strong) ZenitFullscreenHeaderHost *fullscreenHeader;
@end
@implementation WindowWrapper
@end
#import "../render_copy.inc"
#import "../caret_patch_flip.inc"

int main(void) { @autoreleasepool {
    __weak CALayer *retiredHost;
    void *lease;
    @autoreleasepool {
        CAMetalLayer *original = [[CAMetalLayer alloc] init];
        retiredHost = original;
        lease = macos_caret_patch_host_retain((__bridge void *)original);
    }
    @autoreleasepool {
        assert(retiredHost != nil); // weak loads can themselves autorelease a retain
        macos_caret_patch_clear(lease);
        macos_caret_patch_host_release(lease);
        [CATransaction flush];
    }
    assert(retiredHost == nil);
    id<MTLDevice> device = MTLCreateSystemDefaultDevice(); assert(device);
    id<MTLCommandQueue> queue = [device newCommandQueue];
    MTLTextureDescriptor *desc = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm width:64 height:101 mipmapped:NO];
    desc.storageMode = MTLStorageModeShared;
    desc.usage = MTLTextureUsageShaderRead | MTLTextureUsageRenderTarget;
    id<MTLTexture> source = [device newTextureWithDescriptor:desc]; assert(source);
    unsigned char pixels[64*101*4];
    for (unsigned i=0;i<64*101;i++) { pixels[i*4]=i%256; pixels[i*4+1]=37; pixels[i*4+2]=199; pixels[i*4+3]=255; }
    [source replaceRegion:MTLRegionMake2D(0,0,64,101) mipmapLevel:0 withBytes:pixels bytesPerRow:64*4];
    CAMetalLayer *host = [CAMetalLayer layer]; host.device=device;
    host.bounds=CGRectMake(0,0,51.2,80.6); host.geometryFlipped=NO;
    CALayer *overlay=[CALayer layer]; [host addSublayer:overlay];
    float rects[1][4]={{3.3,5.1,1.8,18.6}};
    CFStringRef spaces[]={kCGColorSpaceSRGB,kCGColorSpaceDisplayP3};
    for (unsigned i=0;i<2;i++) {
        CGColorSpaceRef space=CGColorSpaceCreateWithName(spaces[i]); host.colorspace=space;
        id<MTLCommandBuffer> command=[queue commandBuffer];
        assert(macos_caret_patch_encode((__bridge void *)host,(__bridge void *)source,(__bridge void *)command,rects,1,1.25));
        [command commit]; [command waitUntilCompleted]; assert(command.status==MTLCommandBufferStatusCompleted);
        CALayer *patch=host.sublayers[0]; assert(patch!=overlay && host.sublayers.lastObject==overlay);
        unsigned targetRect[4];
        id<MTLTexture> target = (__bridge id<MTLTexture>)macos_caret_patch_target((__bridge void *)host,0,&targetRect);
        assert(target && target.width==8 && target.height==28);
        assert(targetRect[0]==2 && targetRect[1]==4 && targetRect[2]==8 && targetRect[3]==28);
        assert(!macos_caret_patch_target((__bridge void *)host,1,&targetRect));
        assert(patch.zPosition==0 && [patch.contentsFormat isEqual:kCAContentsFormatRGBA8Uint]);
        assert(fabs(patch.frame.origin.y*1.25-69)<0.00001); // source.height=101, not bounds.height*scale=100.75
        IOSurfaceRef surface=(__bridge IOSurfaceRef)patch.contents;
        CFTypeRef spec=IOSurfaceCopyValue(surface,kIOSurfaceColorSpace); assert(spec);
        CGColorSpaceRef encoded=CGColorSpaceCreateWithPropertyList(spec); assert(encoded);
        assert(CFEqual(encoded,space));
        CFRelease(spec); CGColorSpaceRelease(encoded); CGColorSpaceRelease(space);
        macos_caret_patch_show((__bridge void *)host,1);
        unsigned char composite[sizeof(pixels)]; memset(composite,0,sizeof(composite));
        assert(macos_caret_patch_composite((__bridge void *)host,composite,64,101,1.25));
        // Rect pixel bounds x=2..8, y=4..31; actual layer frame reverses to the same grid.
        for (unsigned y=4;y<32;y++) for(unsigned x=2;x<10;x++) assert(!memcmp(composite+(y*64+x)*4,pixels+(y*64+x)*4,4));
    }
    assert(renderCopies==2); // render-copy only; no blit encoder exists in this TU.
    overlay.zPosition=-1;
    id<MTLCommandBuffer> rejected=[queue commandBuffer];
    assert(!macos_caret_patch_encode((__bridge void *)host,(__bridge void *)source,(__bridge void *)rejected,rects,1,1.25));
    assert(macos_caret_patch_count((__bridge void *)host)==0 && host.sublayers.count==1);
    macos_caret_patch_clear((__bridge void *)host); macos_caret_patch_clear((__bridge void *)host);
    assert(host.sublayers[0]==overlay);
    CGColorSpaceRef a=CGColorSpaceCreateWithName(kCGColorSpaceSRGB),b=CGColorSpaceCreateWithName(kCGColorSpaceDisplayP3);
    assert(zenitCaretColorSignature(a)!=zenitCaretColorSignature(b));
    CGColorSpaceRelease(a); CGColorSpaceRelease(b);
    WindowWrapper *wrapper = [WindowWrapper new];
    wrapper.metalView = [[NSView alloc] initWithFrame:NSMakeRect(0,0,100,50)];
    wrapper.metalView.wantsLayer = YES; wrapper.metalView.layer = host;
    wrapper.fullscreenHeader = [ZenitFullscreenHeaderHost new];
    assert(macos_caret_native_ready((__bridge void *)wrapper));
    uint64_t stable = macos_caret_native_signature((__bridge void *)wrapper);
    macos_caret_test_environment((__bridge void *)wrapper, 5);
    assert(!macos_caret_native_ready((__bridge void *)wrapper));
    assert(stable != macos_caret_native_signature((__bridge void *)wrapper));
    macos_caret_test_environment((__bridge void *)wrapper, 6);
    wrapper.fullscreenHeader.pendingFullscreen = YES;
    assert(!macos_caret_native_ready((__bridge void *)wrapper));
    wrapper.fullscreenHeader.pendingFullscreen = NO;
    wrapper.fullscreenHeader.exiting = YES;
    assert(!macos_caret_native_ready((__bridge void *)wrapper));
    wrapper.fullscreenHeader.exiting = NO;
    wrapper.fullscreenHeader.header = [[NSView alloc] initWithFrame:NSMakeRect(0,0,100,38)];
    wrapper.fullscreenHeader.header.wantsLayer = YES;
    CABasicAnimation *slide = [CABasicAnimation animationWithKeyPath:@"position"];
    slide.fromValue = [NSValue valueWithPoint:NSMakePoint(0,0)];
    slide.toValue = [NSValue valueWithPoint:NSMakePoint(0,30)]; slide.duration = 30;
    [wrapper.fullscreenHeader.header.layer addAnimation:slide forKey:@"reveal"];
    assert(!macos_caret_native_ready((__bridge void *)wrapper));
    [wrapper.fullscreenHeader.header.layer removeAllAnimations];
    assert(macos_caret_native_ready((__bridge void *)wrapper));
    stable = macos_caret_native_signature((__bridge void *)wrapper);
    host.drawableSize = CGSizeMake(200,100);
    assert(stable != macos_caret_native_signature((__bridge void *)wrapper));
    puts("caret patch contracts: sRGB/P3 metadata, fractional pixel grid, render copies, overlay ordering and idempotent clear passed");
    return 0;
} }
