// Offscreen renderer + native menu wiring checks; never synthesize input or
// activate a user application. Pass the existing transparent logo and output dir.
#import "macos_menu_bar.m"
#include <assert.h>
static void capture_action(void *raw, uint64_t token) { *(uint64_t *)raw = token; }
int main(int argc, const char **argv) {
    @autoreleasepool {
        assert(argc == 3 || argc == 4);
        [NSApplication sharedApplication];
        NSApp.dockTile.badgeLabel = @"stale";
        NSData *bytes = [NSData dataWithContentsOfFile:@(argv[1])];
        assert(bytes.length && zw_menu_bar_start(bytes.bytes, bytes.length));
        assert(NSApp.dockTile.badgeLabel.length == 0);
        assert(menuBar.item.menu == nil); // Left click must not open a menu.
        assert(menuBar.item.button.imagePosition == NSImageOnly);
        assert(menuBar.item.button.title.length == 0);
        zw_menu_bar_update(4);
        assert([NSApp.dockTile.badgeLabel isEqualToString:@"4"]);
        const unsigned char svg[] = "<svg xmlns='http://www.w3.org/2000/svg' width='14' height='14'><path fill='black' d='M0 0h14v14H0z'/></svg>";
        zw_menu_bar_add_session(3, (const unsigned char *)"same name", 9, svg, sizeof(svg)-1, NULL, 0, 0xee3333ff, 0, false, false, true, (const unsigned char *)"failed", 6);
        zw_menu_bar_add_session(4, (const unsigned char *)"same name", 9, svg, sizeof(svg)-1, NULL, 0, 0x888888ff, 0, false, false, false, (const unsigned char *)"connecting", 10);
        unsigned char rgba[72*72*4];
        for (int y=0;y<72;y++) for (int x=0;x<72;x++) {
            int p=(y*72+x)*4; rgba[p]=x<36?255:0; rgba[p+1]=0; rgba[p+2]=x<36?0:255; rgba[p+3]=255;
        }
        zw_menu_bar_add_session(5, (const unsigned char *)"source colours", 14, NULL, 0, rgba, sizeof(rgba), 0xffffffff, 0, true, true, false, (const unsigned char *)"online", 6);
        NSData *isoftBytes = [NSData dataWithContentsOfFile:argc == 4 ? @(argv[3]) : @"src/ui/assets/host-os/isoft.rgba"];
        assert(isoftBytes.length == 72*72*4);
        zw_menu_bar_add_session(6, (const unsigned char *)"iSoft", 5, NULL, 0, isoftBytes.bytes, isoftBytes.length, 0xffffffff, 0xffffffff, true, false, false, NULL, 0);
        zw_menu_bar_finish();
        assert(menuBar.menu.numberOfItems == 7);
        NSMenuItem *first = [menuBar.menu itemAtIndex:1], *second = [menuBar.menu itemAtIndex:2];
        assert(first.image.valid && first.image.size.width == 14 && !first.image.isTemplate);
        assert(first.state == NSControlStateValueOn && second.state == NSControlStateValueOff);
        assert([first.toolTip isEqualToString:@"failed"] && [second.toolTip isEqualToString:@"connecting"]);
        NSBitmapImageRep *green = [NSBitmapImageRep imageRepWithData:first.image.TIFFRepresentation];
        NSBitmapImageRep *gray = [NSBitmapImageRep imageRepWithData:second.image.TIFFRepresentation];
        NSColor *g = [[green colorAtX:green.pixelsWide/2 y:green.pixelsHigh/2] colorUsingColorSpace:NSColorSpace.sRGBColorSpace];
        NSColor *m = [[gray colorAtX:gray.pixelsWide/2 y:gray.pixelsHigh/2] colorUsingColorSpace:NSColorSpace.sRGBColorSpace];
        assert(g.alphaComponent > .99 && g.redComponent > g.greenComponent + .2);
        assert(fabs(m.redComponent-m.greenComponent) < .01 && fabs(m.greenComponent-m.blueComponent) < .01);
        ZWSessionMenuItem *original = (ZWSessionMenuItem *)[menuBar.menu itemAtIndex:3];
        NSBitmapImageRep *source = [NSBitmapImageRep imageRepWithData:original.image.TIFFRepresentation];
        NSColor *left = [[source colorAtX:source.pixelsWide/4 y:source.pixelsHigh/2] colorUsingColorSpace:NSColorSpace.sRGBColorSpace];
        NSColor *right = [[source colorAtX:source.pixelsWide*3/4 y:source.pixelsHigh/2] colorUsingColorSpace:NSColorSpace.sRGBColorSpace];
        assert(left.redComponent > .9 && left.blueComponent < .1 && right.blueComponent > .9 && right.redComponent < .1);
        // The separate backplate must preserve source ink, keep negative space
        // white, and remain neutral when the foreground uses a state colour.
        ZWSessionMenuItem *isoft = (ZWSessionMenuItem *)[menuBar.menu itemAtIndex:4];
        isoft.iconBackdrop = 0;
        NSBitmapImageRep *bare = [NSBitmapImageRep imageRepWithData:[isoft iconAtOffset:0].TIFFRepresentation];
        isoft.iconBackdrop = 0xffffffff;
        for (int state=0;state<3;state++) {
            isoft.originalColors = state == 0;
            isoft.iconColor = state == 1 ? [NSColor colorWithSRGBRed:.93 green:.2 blue:.2 alpha:1] : NSColor.grayColor;
            NSBitmapImageRep *backed = [NSBitmapImageRep imageRepWithData:[isoft iconAtOffset:0].TIFFRepresentation];
            assert(bare.pixelsWide == backed.pixelsWide && bare.pixelsHigh == backed.pixelsHigh);
            int foreground = 0, white = 0;
            for (NSInteger y=0;y<bare.pixelsHigh;y++) for (NSInteger x=0;x<bare.pixelsWide;x++) {
                NSColor *before = [[bare colorAtX:x y:y] colorUsingColorSpace:NSColorSpace.sRGBColorSpace];
                NSColor *after = [[backed colorAtX:x y:y] colorUsingColorSpace:NSColorSpace.sRGBColorSpace];
                if (before.alphaComponent > .999) {
                    foreground++;
                    if (state == 0) assert(fabs(before.redComponent-after.redComponent)<.02 && fabs(before.greenComponent-after.greenComponent)<.02 && fabs(before.blueComponent-after.blueComponent)<.02);
                    else if (state == 1) assert(after.redComponent > after.greenComponent + .4 && after.redComponent > after.blueComponent + .4);
                    else assert(fabs(after.redComponent-after.greenComponent)<.01 && fabs(after.greenComponent-after.blueComponent)<.01);
                }
                double dx=(x+.5)/bare.pixelsWide-.5, dy=(y+.5)/bare.pixelsHigh-.5;
                if (before.alphaComponent < .001 && dx*dx+dy*dy < .1) {
                    white++;
                    assert(after.alphaComponent>.99 && after.redComponent>.99 && after.greenComponent>.99 && after.blueComponent>.99);
                }
            }
            assert(foreground > 5 && white > 2);
            assert([backed colorAtX:0 y:0].alphaComponent < .1);
            NSString *path = [@(argv[2]) stringByAppendingPathComponent:[NSString stringWithFormat:@"isoft-%@.png",state==0?@"original":state==1?@"failed":@"connecting"]];
            assert([[backed representationUsingType:NSBitmapImageFileTypePNG properties:@{}] writeToFile:path atomically:YES]);
        }
        NSData *resting = original.image.TIFFRepresentation;
        [menuBar menuWillOpen:menuBar.menu];
        assert(menuBar.animationTimer && menuBar.animationTimer.valid);
        menuBar.animationStart = NSProcessInfo.processInfo.systemUptime - .12;
        [menuBar animateSessionIcons];
        assert(![resting isEqualToData:original.image.TIFFRepresentation]);
        // A native tracking loop can outlive the workspace's last bouncing
        // snapshot. It must consume the animation once, including past the
        // former 1600ms repeat boundary, without waiting for another sync.
        menuBar.animationStart = NSProcessInfo.processInfo.systemUptime - 1.72;
        [menuBar animateSessionIcons];
        assert(!original.bouncing && menuBar.animationTimer == nil);
        assert(original.image.size.height == 14);
        NSData *settled = original.image.TIFFRepresentation;
        [menuBar animateSessionIcons];
        assert([settled isEqualToData:original.image.TIFFRepresentation]);
        [menuBar menuDidClose:menuBar.menu];
        assert(menuBar.animationTimer == nil);
        [menuBar menuWillOpen:menuBar.menu];
        assert(menuBar.animationTimer == nil && !original.bouncing);
        for (NSMenuItem *entry in @[first,second,original]) {
            NSBitmapImageRep *rep = [NSBitmapImageRep imageRepWithData:entry.image.TIFFRepresentation];
            NSString *path = [@(argv[2]) stringByAppendingPathComponent:[NSString stringWithFormat:@"session-%@.png",entry==first?@"red":entry==second?@"gray":@"original-bouncing"]];
            assert([[rep representationUsingType:NSBitmapImageFileTypePNG properties:@{}] writeToFile:path atomically:YES]);
        }
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
        NSBitmapImageRep *bareLogo = nil;
        for (int i = 0; i < 4; i++) {
            NSImage *image = [menuBar imageForCount:counts[i]];
            assert(image.size.height == 22 && !image.isTemplate);
            NSBitmapImageRep *rep = [[NSBitmapImageRep alloc] initWithBitmapDataPlanes:NULL pixelsWide:image.size.width*2 pixelsHigh:44 bitsPerSample:8 samplesPerPixel:4 hasAlpha:YES isPlanar:NO colorSpaceName:NSDeviceRGBColorSpace bytesPerRow:0 bitsPerPixel:0];
            [NSGraphicsContext saveGraphicsState];
            NSGraphicsContext.currentContext = [NSGraphicsContext graphicsContextWithBitmapImageRep:rep];
            [image drawInRect:NSMakeRect(0, 0, image.size.width*2, 44)];
            [NSGraphicsContext restoreGraphicsState];
            if (!i) {
                bareLogo = rep;
                NSInteger minY = rep.pixelsHigh, maxY = -1;
                for (NSInteger y=0;y<rep.pixelsHigh;y++) for (NSInteger x=0;x<rep.pixelsWide;x++) {
                    if ([rep colorAtX:x y:y].alphaComponent > 32/255.0) { minY = MIN(minY,y); maxY = MAX(maxY,y); }
                }
                assert(image.size.width == 21 && maxY-minY+1 >= 41 && maxY-minY+1 <= 43);
            }
            else {
                int whiteInk = 0, darkOutline = 0, transparent = 0;
                for (NSInteger y=0;y<28;y++) for (NSInteger x=28;x<rep.pixelsWide;x++) {
                    NSColor *base = x < bareLogo.pixelsWide ? [bareLogo colorAtX:x y:y] : NSColor.clearColor;
                    if (base.alphaComponent > .01) continue;
                    NSColor *pixel = [[rep colorAtX:x y:y] colorUsingColorSpace:NSColorSpace.sRGBColorSpace];
                    if (pixel.alphaComponent > .1) {
                        if (pixel.alphaComponent > .9 && pixel.redComponent > .9 && pixel.greenComponent > .9 && pixel.blueComponent > .9) whiteInk++;
                        if (pixel.alphaComponent > .9 && pixel.redComponent < .55 && pixel.greenComponent < .55 && pixel.blueComponent < .55) darkOutline++;
                    } else transparent++;
                }
                assert(whiteInk > 0 && darkOutline > 0 && transparent > 20);
                assert([rep colorAtX:rep.pixelsWide-1 y:0].alphaComponent < .01);
            }
            NSString *path = [@(argv[2]) stringByAppendingPathComponent:[NSString stringWithFormat:@"badge-%llu.png", (unsigned long long)counts[i]]];
            assert([[rep representationUsingType:NSBitmapImageFileTypePNG properties:@{}] writeToFile:path atomically:YES]);
        }
        // Dock and menu bar share the activity count, including clearing and cap.
        const uint64_t badgeCounts[] = {0, 1, 12, 99, 100, 123, 0};
        NSArray<NSString *> *badgeLabels = @[@"", @"1", @"12", @"99", @"99+", @"99+", @""];
        for (NSUInteger i=0;i<badgeLabels.count;i++) {
            zw_menu_bar_update(badgeCounts[i]);
            assert(menuBar.count == badgeCounts[i]);
            assert([(NSApp.dockTile.badgeLabel ?: @"") isEqualToString:badgeLabels[i]]);
        }
        // Use the production menu boundary for every selective contrast asset.
        // Warning states receive original alpha, never the readability helper.
        NSArray<NSString *> *contrastNames = @[@"debian", @"alpine", @"freebsd", @"bclinux", @"netbsd", @"redflag"];
        NSString *assetDirectory = argc == 4 ? [@(argv[3]) stringByDeletingLastPathComponent] : @"src/ui/assets/host-os";
        for (int state=0;state<3;state++) {
            zw_menu_bar_update(contrastNames.count);
            for (NSUInteger i=0;i<contrastNames.count;i++) {
                NSString *name = contrastNames[i];
                NSString *file = [name stringByAppendingString:state == 0 ? @"-contrast.rgba" : @".rgba"];
                NSData *pixels = [NSData dataWithContentsOfFile:[assetDirectory stringByAppendingPathComponent:file]];
                assert(pixels.length == 72*72*4);
                NSData *title = [name dataUsingEncoding:NSUTF8StringEncoding];
                zw_menu_bar_add_session(20+i, title.bytes, title.length, NULL, 0, pixels.bytes, pixels.length, state==1?0xee3333ff:0x888888ff, 0, state==0, false, false, NULL, 0);
            }
            zw_menu_bar_finish();
            for (NSUInteger i=0;i<contrastNames.count;i++) {
                ZWSessionMenuItem *row = (ZWSessionMenuItem *)[menuBar.menu itemAtIndex:i+1];
                NSBitmapImageRep *rendered = [NSBitmapImageRep imageRepWithData:row.image.TIFFRepresentation];
                assert(row.originalColors == (state==0) && row.iconBackdrop == 0 && rendered.pixelsWide > 0);
                row.originalColors = YES;
                NSBitmapImageRep *untinted = [NSBitmapImageRep imageRepWithData:[row iconAtOffset:0].TIFFRepresentation];
                int visible = 0;
                for (NSInteger y=0;y<rendered.pixelsHigh;y++) for (NSInteger x=0;x<rendered.pixelsWide;x++) {
                    NSColor *pixel = [[rendered colorAtX:x y:y] colorUsingColorSpace:NSColorSpace.sRGBColorSpace];
                    NSColor *before = [[untinted colorAtX:x y:y] colorUsingColorSpace:NSColorSpace.sRGBColorSpace];
                    assert(fabs(pixel.alphaComponent-before.alphaComponent)<.01);
                    if (pixel.alphaComponent > .2) {
                        visible++;
                        if (state==1) assert(pixel.redComponent > pixel.greenComponent+.4 && pixel.redComponent > pixel.blueComponent+.4);
                        if (state==2) assert(fabs(pixel.redComponent-pixel.greenComponent)<.02 && fabs(pixel.greenComponent-pixel.blueComponent)<.02);
                    }
                }
                assert(visible > 5);
                NSString *file = [NSString stringWithFormat:@"contrast-%@-%@.png",contrastNames[i],state==0?@"original":state==1?@"failed":@"connecting"];
                assert([[rendered representationUsingType:NSBitmapImageFileTypePNG properties:@{}] writeToFile:[@(argv[2]) stringByAppendingPathComponent:file] atomically:YES]);
            }
        }
        zw_menu_bar_stop();
        assert(!menuBar);
        assert(NSApp.dockTile.badgeLabel.length == 0);
        puts("PASS: app artwork, selective OS contrast helpers and source-only status masks, synchronized Dock/menu activity badges and clearing, left/right wiring, stable session tokens, quit, cleanup");
    }
}
