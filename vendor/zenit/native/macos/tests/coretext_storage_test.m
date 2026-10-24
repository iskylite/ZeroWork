#import "../coretext_bridge.m"
#import <ImageIO/ImageIO.h>
#include <assert.h>

int main(int argc, char **argv) {
    @autoreleasepool {
        CTFontRef font = CTFontCreateWithName(CFSTR("Menlo"), 22, NULL);
        assert(font);
        // Every isolated surrogate projects to exactly one visible replacement unit.
        for (uint32_t unit = 0xd800; unit <= 0xdfff; unit++) {
            char raw[3] = { (char)(0xe0 | (unit >> 12)), (char)(0x80 | ((unit >> 6) & 63)), (char)(0x80 | (unit & 63)) };
            NSString *s = zenitCTStringFromUTF8(raw, 3);
            assert(s && s.length == 1 && [s characterAtIndex:0] == 0xfffd);
        }
        const char *cases[] = { "A\xed\xa0\x80Z", "A\xed\xb0\x80Z", "A\xed\xa0\xbd\xed\xb8\x80Z", "A\xf0\x9f\x98\x80Z", "\xef\xbb\xbf" "A\xed\xa0\x80Z", "\xef\xbb\xbf\xef\xbb\xbf" "A\xed\xa0\x80Z" };
        unsigned int boundaries[][6] = { {0,1,4,5}, {0,1,4,5}, {0,1,7,8}, {0,1,5,6}, {0,3,4,7,8}, {0,3,6,7,10,11} };
        unsigned int counts[] = {4,4,4,4,5,6};
        for (unsigned int c = 0; c < 6; c++) {
            const unsigned int len = (unsigned int)strlen(cases[c]);
            CoreTextShapedGlyph *glyphs = NULL;
            unsigned int count = 0;
            assert(coretext_shape_text((void *)font, cases[c], len, &glyphs, &count, 0) == 0);
            assert(glyphs && count > 0);
            bool sawLast = false;
            for (unsigned int i = 0; i < count; i++) {
                assert(glyphs[i].cluster < len);
                if (glyphs[i].cluster == len - 1) sawLast = true;
            }
            assert(sawLast);
            if (c < 2) assert([zenitCTStringFromUTF8(cases[c], len) isEqualToString:@"A�Z"]);
            coretext_free_shaped_glyphs(glyphs);
            CoreTextCaretStop stops[6];
            CoreTextLineMetrics metrics;
            assert(coretext_line_caret_stops((void *)font, cases[c], len, boundaries[c], counts[c], stops, &metrics) == 0);
            assert(isfinite(metrics.width) && metrics.width > 0);
            for (unsigned int i = 0; i < counts[c]; i++) {
                assert(stops[i].byte_offset == boundaries[c][i]);
                assert(isfinite(stops[i].primary_x));
            }
            assert(fabs(coretext_measure_text_width_with_font((void *)font, cases[c], len) - metrics.width) < 0.01);
            assert(coretext_measure_text_width_utf8(cases[c], len, 22) > 0);
            assert(coretext_measure_text_width_weighted(cases[c], len, 22, 700) > 0);
        }
        const char *invalid[] = { "\xff", "\xed\xa0", "\xc0\x80", "\xf4\x90\x80\x80" };
        for (unsigned int i = 0; i < 4; i++) assert(zenitCTStringFromUTF8(invalid[i], strlen(invalid[i])) == nil);
        if (argc > 1) {
            CGColorSpaceRef color = CGColorSpaceCreateDeviceRGB();
            CGContextRef ctx = CGBitmapContextCreate(NULL, 480, 180, 8, 480 * 4, color, (CGBitmapInfo)kCGImageAlphaPremultipliedLast);
            assert(ctx);
            CGContextSetRGBFillColor(ctx, 1, 1, 1, 1); CGContextFillRect(ctx, CGRectMake(0,0,480,180));
            for (unsigned int i = 0; i < 5; i++) {
                NSString *text = zenitCTStringFromUTF8(cases[i], strlen(cases[i]));
                CTLineRef line = CTLineCreateWithAttributedString((__bridge CFAttributedStringRef)createAttributedStringWithPreferredSymbolFallback(text, font));
                CGContextSetTextPosition(ctx, 20, 145 - i * 30); CTLineDraw(line, ctx); CFRelease(line);
            }
            CGImageRef img = CGBitmapContextCreateImage(ctx);
            NSURL *url = [NSURL fileURLWithPath:[NSString stringWithUTF8String:argv[1]]];
            CGImageDestinationRef dst = CGImageDestinationCreateWithURL((__bridge CFURLRef)url, CFSTR("public.png"), 1, NULL);
            assert(dst); CGImageDestinationAddImage(dst, img, NULL); assert(CGImageDestinationFinalize(dst));
            CFRelease(dst); CGImageRelease(img); CGContextRelease(ctx); CGColorSpaceRelease(color);
        }
        CFRelease(font);
        puts("PASS: 2048 surrogate units; shaping, caret storage offsets, width, BOM, and invalid-byte rejection");
    }
}
