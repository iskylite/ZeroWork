// No NSWindow, activation, global input or desktop changes. Exercise the real
// Header update against detached native views and a deterministic window model.
#import "../window_bridge.m"
#include "no_render_copy.inc"
#include "empty_a11y.inc"
#include <assert.h>
#include <unistd.h>
uint64_t zenit_text_input_length(uint32_t w) { return 0; }
int zenit_text_input_copy(uint32_t w,uint64_t s,char *b,int n) { return 0; }
int zenit_text_input_selection(uint32_t w,uint32_t *s,uint32_t *e,uint32_t *c) { return 0; }
int zenit_text_input_frame(uint32_t w,uint32_t s,uint32_t e,float *x,float *y,float *a,float *b) { return 0; }
int zenit_text_input_range_at_point(uint32_t w,float x,float y,uint32_t *s,uint32_t *e) { return 0; }
uint64_t zenit_text_input_utf16_for_utf8(uint32_t w,uint64_t n) { return n; }
uint64_t zenit_text_input_utf8_for_utf16(uint32_t w,uint64_t n) { return n; }

@interface MemoryToolbar : NSObject
@property (getter=isVisible) BOOL visible;
@end
@implementation MemoryToolbar
@end
@interface MemoryHeaderWindow : NSObject
@property NSRect frame,contentLayoutRect;
@property (strong) MemoryToolbar *toolbar;
@property (strong) NSView *control;
- (NSButton *)standardWindowButton:(NSWindowButton)kind;
@end
@implementation MemoryHeaderWindow
- (NSButton *)standardWindowButton:(NSWindowButton)kind { return (NSButton *)self.control; }
@end
static void assertPaint(CALayer *layer, NSColor *color) {
    assert(layer.backgroundColor && CGColorEqualToColor(layer.backgroundColor,color.CGColor));
}
static void headerPaint(void) {
    WindowWrapper *owner=[WindowWrapper new];
    MemoryHeaderWindow *window=[MemoryHeaderWindow new];
    window.frame=window.contentLayoutRect=NSMakeRect(0,0,980,600);
    window.toolbar=[MemoryToolbar new];window.toolbar.visible=YES;
    owner.window=(ZenitWindow *)window;
    ZenitFullscreenHeaderHost *host=[ZenitFullscreenHeaderHost new];host.owner=owner;host.height=38;host.policy=2;
    NSView *root=[[NSView alloc] initWithFrame:window.frame];
    host.header=[[ZenitHeaderView alloc] initWithFrame:NSMakeRect(0,0,980,38)];
    host.header.wantsLayer=YES;host.header.layer=[CALayer layer];[root addSubview:host.header];
    host.background=[NSColor colorWithSRGBRed:0.2 green:0.4 blue:0.6 alpha:1];
    [host update]; // Cache B while the native close-button parent is absent.
    assert(host.lastBackground==host.background && !host.controlsBackground);
    window.control=[[NSView alloc] initWithFrame:NSMakeRect(8,8,14,14)];[root addSubview:window.control];
    [host update];assertPaint(host.controlsBackground.layer,host.background);
    host.header.layer=[CALayer layer];[host update];assertPaint(host.header.layer,host.background);
    host.controlsBackground.layer=[CALayer layer];[host update];assertPaint(host.controlsBackground.layer,host.background);
    host.nativeMask=nil;host.controlsBackground.layer.mask=nil;host.controlsBackground.layer.backgroundColor=nil;
    [host update];assert(host.nativeMask);assertPaint(host.controlsBackground.layer,host.background);
    NSView *parent=[[NSView alloc] initWithFrame:root.bounds];[root addSubview:parent];
    [window.control removeFromSuperview];[parent addSubview:window.control];
    host.controlsBackground.layer.backgroundColor=nil;
    [host update];assert(host.controlsBackground.superview==parent);assertPaint(host.controlsBackground.layer,host.background);
    uint64_t work=atomic_load(&g_header_work_updates);
    for(int i=0;i<40;i++) [host update];
    assert(atomic_load(&g_header_work_updates)==work);
    fprintf(stderr,"PASS: delayed controls parent, backing layers, new mask, reparenting and stable Header updates\n");
}
static void append(const char *path,const char *text) {
    FILE *file=fopen(path,"a");assert(file);assert(fputs(text,file)>=0);assert(fclose(file)==0);
}
static void poolLog(void) {
    char path[]="/tmp/zenit-memory-cursor-XXXXXX";int fd=mkstemp(path);assert(fd>=0);close(fd);
    ZenitMissingPoolsCursor cursor={0};
    append(path,"objc[1]: MISSING POOLS: (0x123)");
    assert(zenitReadMissingPools(&cursor,path,0x123)==0 && cursor.offset==0);
    append(path," Object of class Foo just leaking\n");
    assert(zenitReadMissingPools(&cursor,path,0x123)==1);
    off_t offset=cursor.offset;
    assert(zenitReadMissingPools(&cursor,path,0x123)==1 && cursor.offset==offset);
    append(path,"objc[1]: MISSING POOLS: (0x456) wrong thread\nnormal line\n");
    append(path,"objc[1]: MISSING POOLS: (0x123) second\n");
    assert(zenitReadMissingPools(&cursor,path,0x123)==2);
    // A long line split across buffers is still a single record.
    append(path,"objc[1]: MISSING POOLS: (0x123) ");
    char large[6001];memset(large,'x',6000);large[6000]=0;append(path,large);
    assert(zenitReadMissingPools(&cursor,path,0x123)==2);
    append(path,"\n");assert(zenitReadMissingPools(&cursor,path,0x123)==3);
    assert(truncate(path,0)==0);assert(zenitReadMissingPools(&cursor,path,0x123)==0 && cursor.offset==0);
    append(path,"objc[1]: MISSING POOLS: (0x123) after truncate\n");assert(zenitReadMissingPools(&cursor,path,0x123)==1);
    char rotated[256];snprintf(rotated,sizeof(rotated),"%s.old",path);assert(rename(path,rotated)==0);
    append(path,"normal replacement file\n");assert(zenitReadMissingPools(&cursor,path,0x123)==0);
    unlink(path);unlink(rotated);
    fprintf(stderr,"PASS: incremental pool log, partial/long lines, thread filtering, truncation and rotation\n");
}
int main(void) {
    @autoreleasepool {
        headerPaint();poolLog();
        uint64_t before=atomic_load(&g_live_wrappers);
        dispatch_apply(1000,dispatch_get_global_queue(QOS_CLASS_DEFAULT,0),^(size_t i) {
            @autoreleasepool { WindowWrapper *wrapper=[WindowWrapper new];assert(wrapper); }
        });
        assert(atomic_load(&g_live_wrappers)==before);
        fprintf(stderr,"PASS: concurrent native wrapper init/dealloc counters\n");
    }
    return 0;
}
