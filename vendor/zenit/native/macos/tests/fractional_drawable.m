#import <Cocoa/Cocoa.h>
#import <Metal/Metal.h>
#import <QuartzCore/CAMetalLayer.h>
#import <objc/runtime.h>

static char windowKey;
void *zenit_test_fractional_layer(double *width, double *height) {
    [NSApplication sharedApplication];
    NSWindow *window=[[NSWindow alloc] initWithContentRect:NSMakeRect(40,40,400.2,300.2)
        styleMask:NSWindowStyleMaskBorderless backing:NSBackingStoreBuffered defer:NO];
    window.releasedWhenClosed=NO;
    NSView *view=window.contentView;
    view.wantsLayer=YES;
    CAMetalLayer *layer=[CAMetalLayer layer];
    layer.device=MTLCreateSystemDefaultDevice();
    layer.pixelFormat=MTLPixelFormatBGRA8Unorm;
    layer.framebufferOnly=NO;
    layer.contentsScale=2;
    view.layer=layer;
    [window orderBack:nil];
    [view setBoundsSize:NSMakeSize(400.2,300.2)];
    *width=view.bounds.size.width; *height=view.bounds.size.height;
    layer.drawableSize=CGSizeMake(*width*2,*height*2);
    objc_setAssociatedObject(layer,&windowKey,window,OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    return (__bridge_retained void *)layer;
}
void zenit_test_fractional_layer_reset(void *raw, double width, double height) {
    CAMetalLayer *layer=(__bridge CAMetalLayer *)raw;
    NSWindow *window=objc_getAssociatedObject(layer,&windowKey);
    [window.contentView setBoundsSize:NSMakeSize(width,height)];
    layer.drawableSize=CGSizeMake(window.contentView.bounds.size.width*2,window.contentView.bounds.size.height*2);
}
void zenit_test_fractional_layer_destroy(void *raw) {
    CAMetalLayer *layer=(__bridge_transfer CAMetalLayer *)raw;
    NSWindow *window=objc_getAssociatedObject(layer,&windowKey);
    [window orderOut:nil]; [window close];
    objc_setAssociatedObject(layer,&windowKey,nil,OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}
void zenit_test_write_bgra8(const char *path, unsigned char *pixels, unsigned width, unsigned height) {
    NSBitmapImageRep *image=[[NSBitmapImageRep alloc] initWithBitmapDataPlanes:NULL
        pixelsWide:width pixelsHigh:height bitsPerSample:8 samplesPerPixel:4 hasAlpha:YES
        isPlanar:NO colorSpaceName:NSDeviceRGBColorSpace bytesPerRow:width*4 bitsPerPixel:32];
    unsigned char *rgba=image.bitmapData;
    for (size_t i=0;i<(size_t)width*height;++i) {
        rgba[4*i]=pixels[4*i+2];rgba[4*i+1]=pixels[4*i+1];
        rgba[4*i+2]=pixels[4*i];rgba[4*i+3]=pixels[4*i+3];
    }
    NSData *png=[image representationUsingType:NSBitmapImageFileTypePNG properties:@{}];
    if (![png writeToFile:[NSString stringWithUTF8String:path] atomically:YES]) abort();
}
