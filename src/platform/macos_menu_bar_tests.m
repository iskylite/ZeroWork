// Offscreen renderer + native menu wiring checks; never synthesize input or
// activate a user application. Pass the existing transparent logo and output dir.
#import "macos_menu_bar.m"
#include <assert.h>
static void capture_action(void *raw, uint64_t token) { *(uint64_t *)raw = token; }
int main(int argc, const char **argv) {
    @autoreleasepool {
        assert(argc == 3);
        [NSApplication sharedApplication];
        NSData *bytes = [NSData dataWithContentsOfFile:@(argv[1])];
        assert(bytes.length && zw_menu_bar_start(bytes.bytes, bytes.length));
        assert(menuBar.item.menu == nil); // Left click must not open a menu.
        assert(menuBar.item.button.imagePosition == NSImageOnly);
        assert(menuBar.item.button.title.length == 0);
        zw_menu_bar_update(2);
        const unsigned char svg[] = "<svg xmlns='http://www.w3.org/2000/svg' width='14' height='14'><path fill='black' d='M0 0h14v14H0z'/></svg>";
        zw_menu_bar_add_session(3, (const unsigned char *)"same name", 9, svg, sizeof(svg)-1, 0x35a468ff, true, (const unsigned char *)"online", 6);
        zw_menu_bar_add_session(4, (const unsigned char *)"same name", 9, svg, sizeof(svg)-1, 0x888888ff, false, (const unsigned char *)"offline", 7);
        zw_menu_bar_finish();
        assert(menuBar.menu.numberOfItems == 5);
        NSMenuItem *first = [menuBar.menu itemAtIndex:1], *second = [menuBar.menu itemAtIndex:2];
        assert(first.image.valid && first.image.size.width == 14 && !first.image.isTemplate);
        assert(first.state == NSControlStateValueOn && second.state == NSControlStateValueOff);
        assert([first.toolTip isEqualToString:@"online"] && [second.toolTip isEqualToString:@"offline"]);
        NSBitmapImageRep *green = [NSBitmapImageRep imageRepWithData:first.image.TIFFRepresentation];
        NSBitmapImageRep *gray = [NSBitmapImageRep imageRepWithData:second.image.TIFFRepresentation];
        NSColor *g = [[green colorAtX:green.pixelsWide/2 y:green.pixelsHigh/2] colorUsingColorSpace:NSColorSpace.sRGBColorSpace];
        NSColor *m = [[gray colorAtX:gray.pixelsWide/2 y:gray.pixelsHigh/2] colorUsingColorSpace:NSColorSpace.sRGBColorSpace];
        assert(g.alphaComponent > .99 && g.greenComponent > g.redComponent + .2);
        assert(fabs(m.redComponent-m.greenComponent) < .01 && fabs(m.greenComponent-m.blueComponent) < .01);
        [menuBar selectSession:[menuBar.menu itemAtIndex:2]];
        assert(zw_menu_bar_take_action() == 4 && zw_menu_bar_take_action() == 0);
        uint64_t immediate = 0;
        zw_menu_bar_set_action_handler(&immediate, capture_action);
        [menuBar selectSession:[menuBar.menu itemAtIndex:1]];
        assert(immediate == 3 && zw_menu_bar_take_action() == 0);
        zw_menu_bar_set_action_handler(NULL, NULL);
        [menuBar quit:nil];
        assert(zw_menu_bar_take_action() == 2);
        // Render identical production drawing code at native Retina scale.
        const uint64_t counts[] = {0, 1, 12, 123};
        for (int i = 0; i < 4; i++) {
            NSImage *image = [menuBar imageForCount:counts[i]];
            assert(image.size.height == 22 && !image.isTemplate);
            NSBitmapImageRep *rep = [[NSBitmapImageRep alloc] initWithBitmapDataPlanes:NULL pixelsWide:image.size.width*2 pixelsHigh:44 bitsPerSample:8 samplesPerPixel:4 hasAlpha:YES isPlanar:NO colorSpaceName:NSDeviceRGBColorSpace bytesPerRow:0 bitsPerPixel:0];
            [NSGraphicsContext saveGraphicsState];
            NSGraphicsContext.currentContext = [NSGraphicsContext graphicsContextWithBitmapImageRep:rep];
            [image drawInRect:NSMakeRect(0, 0, image.size.width*2, 44)];
            [NSGraphicsContext restoreGraphicsState];
            NSString *path = [@(argv[2]) stringByAppendingPathComponent:[NSString stringWithFormat:@"badge-%llu.png", (unsigned long long)counts[i]]];
            assert([[rep representationUsingType:NSBitmapImageFileTypePNG properties:@{}] writeToFile:path atomically:YES]);
        }
        zw_menu_bar_stop();
        assert(!menuBar);
        puts("PASS: app artwork, corner badge rendering (0/1/12/99+), separate left/right wiring, stable same-name session tokens, quit action, cleanup");
    }
}
