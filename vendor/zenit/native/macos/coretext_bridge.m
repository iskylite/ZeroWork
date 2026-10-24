#import <CoreText/CoreText.h>
#import <CoreGraphics/CoreGraphics.h>
#import <Foundation/Foundation.h>
#include <stdlib.h>
#include <string.h>
#include <limits.h>
#include <math.h>

static NSString *zenitCTStringFromUTF8(const char *bytes, NSUInteger len);

// ============================================================================
// Font Creation
// ============================================================================

/// Derive a new CTFont from an existing one at a different size.
/// Preserves all variation axes (weight, italic) from the original font.
void* coretext_derive_font(void* existing_font, float new_size) {
    CTFontRef src = (CTFontRef)existing_font;
    // CTFontCreateCopyWithAttributes with NULL descriptor preserves all axes
    CTFontRef derived = CTFontCreateCopyWithAttributes(src, new_size, NULL, NULL);
    if (!derived) {
        NSLog(@"[CoreText] coretext_derive_font: failed to derive at size %.1f", new_size);
        return NULL;
    }
    return (void*)derived;
}

char* coretext_font_copy_debug_name(void* font) {
    @autoreleasepool {
        if (!font) return NULL;

        CTFontRef ctFont = (CTFontRef)font;
        CFStringRef fullNameRef = CTFontCopyFullName(ctFont);
        CFStringRef familyRef = CTFontCopyFamilyName(ctFont);
        CFStringRef postScriptRef = CTFontCopyPostScriptName(ctFont);
        float size = (float)CTFontGetSize(ctFont);

        NSString *fullName = fullNameRef ? (__bridge_transfer NSString *)fullNameRef : @"<unknown>";
        NSString *familyName = familyRef ? (__bridge_transfer NSString *)familyRef : @"<unknown>";
        NSString *postScriptName = postScriptRef ? (__bridge_transfer NSString *)postScriptRef : @"<unknown>";
        NSString *debugName = [NSString stringWithFormat:@"%@ | family=%@ | ps=%@ | size=%.2f",
                               fullName, familyName, postScriptName, size];
        const char *utf8 = debugName.UTF8String;
        if (!utf8) return NULL;

        size_t len = strlen(utf8);
        char *out = (char *)malloc(len + 1);
        if (!out) return NULL;
        memcpy(out, utf8, len + 1);
        return out;
    }
}

void coretext_free_c_string(char* str) {
    if (str) free(str);
}

/// Create a font from a file path at a specific size
void* coretext_create_font_from_path(const char* path, float size) {
    @autoreleasepool {
        NSString *nsPath = [NSString stringWithUTF8String:path];
        NSURL *url = [NSURL fileURLWithPath:nsPath];

        CGDataProviderRef provider = CGDataProviderCreateWithURL((__bridge CFURLRef)url);
        if (!provider) {
            NSLog(@"[CoreText] Failed to create data provider for: %s", path);
            return NULL;
        }

        CGFontRef cgFont = CGFontCreateWithDataProvider(provider);
        CGDataProviderRelease(provider);
        if (!cgFont) {
            NSLog(@"[CoreText] Failed to create CGFont from: %s", path);
            return NULL;
        }

        CTFontRef font = CTFontCreateWithGraphicsFont(cgFont, size, NULL, NULL);
        CGFontRelease(cgFont);

        if (!font) {
            NSLog(@"[CoreText] Failed to create CTFont from: %s", path);
            return NULL;
        }

        NSLog(@"[CoreText] Loaded font from path: %s @ %.0fpt", path, size);
        return (void*)font;
    }
}

/// Find a system font by family name, size, weight, and italic flag
void* coretext_find_font(const char* family, float size, int weight, int italic) {
    @autoreleasepool {
        // Map weight int to CTFontWeight
        // weight: 100=thin, 200=ultralight, 300=light, 400=regular,
        //         500=medium, 600=semibold, 700=bold, 800=heavy, 900=black
        CGFloat ctWeight;
        if (weight <= 100) ctWeight = -0.8;        // UIFontWeightUltraLight
        else if (weight <= 200) ctWeight = -0.6;   // UIFontWeightThin
        else if (weight <= 300) ctWeight = -0.4;   // UIFontWeightLight
        else if (weight <= 400) ctWeight = 0.0;    // UIFontWeightRegular
        else if (weight <= 500) ctWeight = 0.23;   // UIFontWeightMedium
        else if (weight <= 600) ctWeight = 0.3;    // UIFontWeightSemibold
        else if (weight <= 700) ctWeight = 0.4;    // UIFontWeightBold
        else if (weight <= 800) ctWeight = 0.56;   // UIFontWeightHeavy
        else ctWeight = 0.62;                      // UIFontWeightBlack

        NSString *familyName = [NSString stringWithUTF8String:family];

        // "system-ui": the platform UI font (SF Pro). Its family is hidden from descriptor
        // lookups; CTFontCreateUIFontForLanguage gives it with the size's optical size and
        // tracking, and a weight trait picks the instance.
        if ([familyName isEqualToString:@"system-ui"]) {
            CTFontRef sys = CTFontCreateUIFontForLanguage(kCTFontUIFontSystem, size, NULL);
            if (!sys) return NULL;
            CTFontDescriptorRef base = CTFontCopyFontDescriptor(sys);
            if (!base) { CFRelease(sys); return NULL; }
            NSMutableDictionary *t = [NSMutableDictionary dictionaryWithObject:@(ctWeight) forKey:(id)kCTFontWeightTrait];
            // the traits attribute replaces the base's: keep its symbolic bits, add italic
            if (italic) t[(id)kCTFontSymbolicTrait] = @(CTFontGetSymbolicTraits(sys) | kCTFontItalicTrait);
            CTFontDescriptorRef desc = CTFontDescriptorCreateCopyWithAttributes(base, (__bridge CFDictionaryRef)@{ (id)kCTFontTraitsAttribute: t });
            CFRelease(base);
            CFRelease(sys);
            if (!desc) return NULL;
            CTFontRef font = CTFontCreateWithFontDescriptor(desc, size, NULL);
            CFRelease(desc);
            return (void*)font;
        }

        // Build font attributes
        NSMutableDictionary *attrs = [NSMutableDictionary dictionary];
        attrs[(id)kCTFontFamilyNameAttribute] = familyName;
        attrs[(id)kCTFontSizeAttribute] = @(size);

        // Build traits
        NSMutableDictionary *traits = [NSMutableDictionary dictionary];
        traits[(id)kCTFontWeightTrait] = @(ctWeight);
        if (italic) {
            // Use symbolic trait to request italic variant
            traits[(id)kCTFontSymbolicTrait] = @(kCTFontItalicTrait);
        }
        attrs[(id)kCTFontTraitsAttribute] = traits;

        CTFontDescriptorRef descriptor = CTFontDescriptorCreateWithAttributes((__bridge CFDictionaryRef)attrs);
        CTFontRef font = CTFontCreateWithFontDescriptor(descriptor, size, NULL);
        CFRelease(descriptor);

        if (!font) {
            NSLog(@"[CoreText] Failed to find font: %s", family);
            return NULL;
        }

        // Verify returned font actually has italic trait
        if (italic) {
            CTFontSymbolicTraits actualTraits = CTFontGetSymbolicTraits(font);
            if (!(actualTraits & kCTFontItalicTrait)) {
                // Font family has no italic variant, CoreText fell back to non-italic
                NSLog(@"[CoreText] Font %s has no italic variant, rejecting", family);
                CFRelease(font);
                return NULL;
            }
        }

        const char *style = italic ? "italic" : "regular";
        NSLog(@"[CoreText] Found system font: %s @ %.0fpt (weight=%d, style=%s)", family, size, weight, style);
        return (void*)font;
    }
}

/// Create a font from a file path with Variable Font weight/italic axis support
/// weight: CSS numeric weight (400=regular, 600=semibold, 700=bold, etc.)
/// italic: 0=normal, 1=italic (sets 'ital' axis to 1.0)
void* coretext_create_font_from_path_weighted(const char* path, float size, int weight, int italic) {
    @autoreleasepool {
        NSString *nsPath = [NSString stringWithUTF8String:path];
        NSURL *url = [NSURL fileURLWithPath:nsPath];

        CGDataProviderRef provider = CGDataProviderCreateWithURL((__bridge CFURLRef)url);
        if (!provider) {
            NSLog(@"[CoreText] Failed to create data provider for: %s", path);
            return NULL;
        }

        CGFontRef cgFont = CGFontCreateWithDataProvider(provider);
        CGDataProviderRelease(provider);
        if (!cgFont) {
            NSLog(@"[CoreText] Failed to create CGFont from: %s", path);
            return NULL;
        }

        // Step 1: Create base CTFont from CGFont (no variation yet)
        CTFontRef baseFont = CTFontCreateWithGraphicsFont(cgFont, size, NULL, NULL);
        CGFontRelease(cgFont);
        if (!baseFont) {
            NSLog(@"[CoreText] Failed to create base CTFont from: %s", path);
            return NULL;
        }

        // Step 2: Apply variation axes via CTFontCreateCopyWithAttributes
        // kCTFontVariationAttribute expects dict of { NSNumber(axis_tag) : NSNumber(value) }
        NSMutableDictionary *variations = [NSMutableDictionary dictionary];
        variations[@(0x77676874)] = @((CGFloat)weight);  // 'wght'
        if (italic) {
            variations[@(0x6974616C)] = @(1.0);          // 'ital'
        }

        NSDictionary *varAttrs = @{
            (id)kCTFontVariationAttribute: variations
        };
        CTFontDescriptorRef varDesc = CTFontDescriptorCreateWithAttributes((__bridge CFDictionaryRef)varAttrs);
        CTFontRef font = CTFontCreateCopyWithAttributes(baseFont, size, NULL, varDesc);
        CFRelease(varDesc);
        CFRelease(baseFont);

        if (!font) {
            NSLog(@"[CoreText] Failed to create VF CTFont from: %s", path);
            return NULL;
        }

        const char *style = italic ? "italic" : "regular";
        NSLog(@"[CoreText] Loaded VF font: %s @ %.0fpt (weight=%d, style=%s)", path, size, weight, style);
        return (void*)font;
    }
}

/// Release a font
void coretext_release_font(void* font) {
    if (font) {
        CFRelease((CTFontRef)font);
    }
}

/// Retain a font (increment reference count)
void coretext_retain_font(void* font) {
    if (font) {
        CFRetain((CTFontRef)font);
    }
}

// ============================================================================
// Font Metrics
// ============================================================================

float coretext_font_get_ascent(void* font) {
    return (float)CTFontGetAscent((CTFontRef)font);
}

float coretext_font_get_descent(void* font) {
    return (float)CTFontGetDescent((CTFontRef)font);
}

float coretext_font_get_leading(void* font) {
    return (float)CTFontGetLeading((CTFontRef)font);
}

unsigned int coretext_font_get_units_per_em(void* font) {
    return (unsigned int)CTFontGetUnitsPerEm((CTFontRef)font);
}

float coretext_font_get_size(void* font) {
    return (float)CTFontGetSize((CTFontRef)font);
}

/// Font **stable identity** hash: FNV-1a of PostScript name + size + symbolic traits.
///
/// Reason: the run-level fallback CTFontRef returned by CoreText shaping is **not a stable
/// pointer**: the same "PingFangSC-Regular 14pt" is two instances across shapes.
/// Using the pointer as cache key rebuilds wrapper Fonts every frame, the glyph atlas
/// repeats the same glyph under different font_ptr and fills its 32 pages, and later glyphs
/// are silently dropped (CJK characters disappear one by one, ASCII unaffected).
unsigned long long coretext_font_identity_hash(void* font) {
    CTFontRef f = (CTFontRef)font;
    unsigned long long h = 1469598103934665603ULL;
    CFStringRef name = CTFontCopyPostScriptName(f);
    if (name) {
        char buf[256];
        if (CFStringGetCString(name, buf, sizeof(buf), kCFStringEncodingUTF8)) {
            for (const char* q = buf; *q; q++) { h ^= (unsigned char)*q; h *= 1099511628211ULL; }
        }
        CFRelease(name);
    }
    float size = (float)CTFontGetSize(f);
    unsigned int sbits; memcpy(&sbits, &size, sizeof(sbits));
    h ^= sbits; h *= 1099511628211ULL;
    unsigned int traits = (unsigned int)CTFontGetSymbolicTraits(f);
    h ^= traits; h *= 1099511628211ULL;
    return h;
}

/// Helper: create a CTFont from weight (CSS numeric weight: 400=regular, 700=bold, etc.)
static CTFontRef createFontWithWeight(float font_size, int weight) {
    CGFloat ctWeight;
    if (weight <= 100) ctWeight = -0.8;
    else if (weight <= 200) ctWeight = -0.6;
    else if (weight <= 300) ctWeight = -0.4;
    else if (weight <= 400) ctWeight = 0.0;
    else if (weight <= 500) ctWeight = 0.23;
    else if (weight <= 600) ctWeight = 0.3;
    else if (weight <= 700) ctWeight = 0.4;
    else if (weight <= 800) ctWeight = 0.56;
    else ctWeight = 0.62;

    CTFontRef sysFont = CTFontCreateUIFontForLanguage(kCTFontUIFontSystem, font_size, NULL);
    if (!sysFont) return NULL;

    NSDictionary *traits = @{ (id)kCTFontWeightTrait: @(ctWeight) };
    NSDictionary *attrs = @{
        (id)kCTFontFamilyNameAttribute: @"PingFang SC",
        (id)kCTFontTraitsAttribute: traits
    };
    CTFontDescriptorRef desc = CTFontDescriptorCreateWithAttributes((__bridge CFDictionaryRef)attrs);
    CTFontRef font = CTFontCreateCopyWithAttributes(sysFont, font_size, NULL, desc);
    CFRelease(desc);
    CFRelease(sysFont);
    return font;
}

static int cssWeightFromCTFont(CTFontRef font) {
    if (!font) return 400;

    CFDictionaryRef traits = CTFontCopyTraits(font);
    if (!traits) return 400;

    CGFloat ctWeight = 0.0;
    CFNumberRef weightNumber = CFDictionaryGetValue(traits, kCTFontWeightTrait);
    if (weightNumber) {
        CFNumberGetValue(weightNumber, kCFNumberCGFloatType, &ctWeight);
    }
    CFRelease(traits);

    if (ctWeight <= -0.7) return 100;
    if (ctWeight <= -0.5) return 200;
    if (ctWeight <= -0.2) return 300;
    if (ctWeight <= 0.1) return 400;
    if (ctWeight <= 0.26) return 500;
    if (ctWeight <= 0.35) return 600;
    if (ctWeight <= 0.48) return 700;
    if (ctWeight <= 0.59) return 800;
    return 900;
}

static int shouldPreferSymbolFallbackForCodepoint(uint32_t codepoint) {
    return codepoint >= 0x2460 && codepoint <= 0x24FF;
}

/// SMP emoji plane (U+1F000-U+1FAFF) defaults to emoji presentation but must
/// explicitly specify Apple Color Emoji: CoreText cascade is run-context-dependent.
/// Isolated shaping resolves to Apple Color Emoji (advance ~1.33em), but a whole sequence
/// after a CJK run gets taken by PingFang (advance 1em). Inconsistent advance between
/// paths breaks caret/selection/width. Force the emoji font to keep run segmentation
/// consistent. VS15 (U+FE0E) explicitly requests text presentation; skip.
///
/// WARNING: Force entire ZWJ sequences, not per-codepoint. ZWJ (U+200D) is BMP;
/// if only SMP members get the emoji font, sequences split into multiple attribute runs.
/// CTLine won't knit across runs, breaking a family emoji sequence into three separate
/// glyphs (21->63px).
static int shouldForceEmojiFallbackForCodepoint(uint32_t codepoint) {
    return codepoint >= 0x1F000 && codepoint <= 0x1FAFF;
}

static CTFontRef createEmojiFallbackFont(CTFontRef baseFont) {
    const float fontSize = baseFont ? (float)CTFontGetSize(baseFont) : 14.0f;
    return CTFontCreateWithName(CFSTR("AppleColorEmoji"), fontSize, NULL);
}

static CTFontRef createPreferredSymbolFallbackFontForBaseFont(CTFontRef baseFont) {
    const float fontSize = baseFont ? (float)CTFontGetSize(baseFont) : 14.0f;
    const int fontWeight = cssWeightFromCTFont(baseFont);
    return createFontWithWeight(fontSize, fontWeight);
}

static NSAttributedString* createAttributedStringWithPreferredSymbolFallback(NSString *text, CTFontRef baseFont) {
    NSDictionary *attrs = @{
        (id)kCTFontAttributeName: (__bridge id)baseFont
    };
    NSMutableAttributedString *attr = [[NSMutableAttributedString alloc] initWithString:text
                                                                             attributes:attrs];

    CTFontRef fallbackFont = NULL;
    CTFontRef emojiFont = NULL;
    const NSUInteger utf16Len = text.length;
    for (NSUInteger i = 0; i < utf16Len; i++) {
        unichar ch = [text characterAtIndex:i];
        uint32_t codepoint = ch;
        NSUInteger charLen = 1;
        if (CFStringIsSurrogateHighCharacter(ch) && i + 1 < utf16Len) {
            unichar low = [text characterAtIndex:(i + 1)];
            if (CFStringIsSurrogateLowCharacter(low)) {
                codepoint = CFStringGetLongCharacterForSurrogatePair(ch, low);
                charLen = 2;
            }
        }

        if (shouldPreferSymbolFallbackForCodepoint(codepoint)) {
            if (!fallbackFont) {
                fallbackFont = createPreferredSymbolFallbackFontForBaseFont(baseFont);
            }
            if (fallbackFont) {
                [attr addAttribute:(id)kCTFontAttributeName
                             value:(__bridge id)fallbackFont
                             range:NSMakeRange(i, charLen)];
            }
        }

        i += charLen - 1;
    }

    // Second pass: force emoji per ZWJ-connected sequence (cluster). Cluster = codepoints
    // optionally with VS16/VS15, joined by ZWJ. If any member falls in forced range and
    // not VS15-suppressed, cover entire cluster (including ZWJ, VS16, and BMP members
    // like ❤) with same emoji font to ensure consistent metrics/rendering/caret.
    NSUInteger ci = 0;
    while (ci < utf16Len) {
        const NSUInteger clusterStart = ci;
        BOOL forced = NO;
        while (ci < utf16Len) {
            unichar ch = [text characterAtIndex:ci];
            uint32_t codepoint = ch;
            NSUInteger charLen = 1;
            if (CFStringIsSurrogateHighCharacter(ch) && ci + 1 < utf16Len) {
                unichar low = [text characterAtIndex:(ci + 1)];
                if (CFStringIsSurrogateLowCharacter(low)) {
                    codepoint = CFStringGetLongCharacterForSurrogatePair(ch, low);
                    charLen = 2;
                }
            }
            BOOL memberForced = shouldForceEmojiFallbackForCodepoint(codepoint) ? YES : NO;
            ci += charLen;
            if (ci < utf16Len) {
                unichar vs = [text characterAtIndex:ci];
                if (vs == 0xFE0E) { // VS15: explicit text presentation for this member
                    memberForced = NO;
                    ci += 1;
                } else if (vs == 0xFE0F) { // VS16: explicit emoji presentation
                    ci += 1;
                }
            }
            if (memberForced) forced = YES;
            // Only ZWJ continues cluster; any other character ends it
            if (ci < utf16Len && [text characterAtIndex:ci] == 0x200D) {
                ci += 1;
                continue;
            }
            break;
        }
        if (forced) {
            if (!emojiFont) emojiFont = createEmojiFallbackFont(baseFont);
            if (emojiFont) {
                [attr addAttribute:(id)kCTFontAttributeName
                             value:(__bridge id)emojiFont
                             range:NSMakeRange(clusterStart, ci - clusterStart)];
            }
        }
    }

    if (fallbackFont) CFRelease(fallbackFont);
    if (emojiFont) CFRelease(emojiFont);
    return attr;
}

/// Measure UTF-8 text width using an existing CTFontRef (no font creation/release)
float coretext_measure_text_width_with_font(void* font_ptr, const char* text, int len) {
    @autoreleasepool {
        if (!font_ptr || !text || len <= 0) return 0.0f;

        NSString *nsText = zenitCTStringFromUTF8(text, (NSUInteger)len);
        if (!nsText || nsText.length == 0) return 0.0f;

        CTFontRef font = (CTFontRef)font_ptr;
        NSAttributedString *attr = createAttributedStringWithPreferredSymbolFallback(nsText, font);
        CTLineRef line = CTLineCreateWithAttributedString((__bridge CFAttributedStringRef)attr);
        double width = CTLineGetTypographicBounds(line, NULL, NULL, NULL);

        CFRelease(line);
        return (float)width;
    }
}

/// Measure UTF-8 text width with macOS text shaping (logical pixels)
float coretext_measure_text_width_utf8(const char* text, int len, float font_size) {
    if (!text || len <= 0) return 0.0f;

    NSString *nsText = zenitCTStringFromUTF8(text, (NSUInteger)len);
    if (!nsText || nsText.length == 0) return 0.0f;

    CTFontRef font = CTFontCreateWithName(CFSTR("PingFang SC"), font_size, NULL);
    if (!font) {
        font = CTFontCreateWithName(CFSTR("Helvetica Neue"), font_size, NULL);
    }
    if (!font) return 0.0f;

    NSDictionary *attrs = @{
        (id)kCTFontAttributeName: (__bridge id)font
    };
    NSAttributedString *attr = [[NSAttributedString alloc] initWithString:nsText attributes:attrs];
    CTLineRef line = CTLineCreateWithAttributedString((__bridge CFAttributedStringRef)attr);
    double width = CTLineGetTypographicBounds(line, NULL, NULL, NULL);

    CFRelease(line);
    CFRelease(font);
    return (float)width;
}

/// Measure UTF-8 text width with font weight support (logical pixels)
float coretext_measure_text_width_weighted(const char* text, int len, float font_size, int font_weight) {
    @autoreleasepool {
        if (!text || len <= 0) return 0.0f;
        // weight == 400: use existing logic (perf optimization)
        if (font_weight <= 400) return coretext_measure_text_width_utf8(text, len, font_size);

        NSString *nsText = zenitCTStringFromUTF8(text, (NSUInteger)len);
        if (!nsText || nsText.length == 0) return 0.0f;

        CTFontRef font = createFontWithWeight(font_size, font_weight);
        if (!font) return coretext_measure_text_width_utf8(text, len, font_size);

        NSDictionary *attrs = @{
            (id)kCTFontAttributeName: (__bridge id)font
        };
        NSAttributedString *attr = [[NSAttributedString alloc] initWithString:nsText attributes:attrs];
        CTLineRef line = CTLineCreateWithAttributedString((__bridge CFAttributedStringRef)attr);
        double width = CTLineGetTypographicBounds(line, NULL, NULL, NULL);

        CFRelease(line);
        CFRelease(font);
        return (float)width;
    }
}

/// Get glyph index for a character
unsigned int coretext_font_get_glyph_index(void* font, unsigned int codepoint) {
    @autoreleasepool {
        UniChar chars[2];
        CGGlyph glyphs[2];
        int count;

        // Handle surrogate pairs for codepoints > 0xFFFF
        if (codepoint > 0xFFFF) {
            codepoint -= 0x10000;
            chars[0] = (UniChar)(0xD800 + (codepoint >> 10));
            chars[1] = (UniChar)(0xDC00 + (codepoint & 0x3FF));
            count = 2;
        } else {
            chars[0] = (UniChar)codepoint;
            count = 1;
        }

        if (CTFontGetGlyphsForCharacters((CTFontRef)font, chars, glyphs, count)) {
            return (unsigned int)glyphs[0];
        }
        return 0;
    }
}

// ============================================================================
// Glyph Rasterization
// ============================================================================

/// Detect whether a font has a color glyph table. Decided per font, not per codepoint
/// (Extended_Pictographic), because rasterization depends on the selected font: a pictographic
/// codepoint in a text-presentation or monochrome font stays single-channel, while some
/// non-pictographic codepoints (tag sequences, symbols) are color in Apple Color Emoji.
/// CoreText fallback has already picked the font, so checking its tables is unambiguous.
/// sbix (Apple bitmap), COLR (layered vector) and CBDT (Google bitmap) cover all color formats.
int coretext_font_has_color_glyphs(void* font_ptr) {
    @autoreleasepool {
        if (!font_ptr) return 0;
        CTFontRef font = (CTFontRef)font_ptr;

        // CTFontGetSymbolicTraits kCTFontTraitColorGlyphs is direct but unreliable for
        // third-party color fonts; check tables as fallback.
        if (CTFontGetSymbolicTraits(font) & kCTFontTraitColorGlyphs) {
            return 1;
        }

        const uint32_t tags[3] = {
            kCTFontTableSbix,
            kCTFontTableCOLR,
            'CBDT',
        };
        for (int i = 0; i < 3; i++) {
            CFDataRef table = CTFontCopyTable(font, (CTFontTableTag)tags[i],
                                              kCTFontTableOptionNoOptions);
            if (table) {
                CFRelease(table);
                return 1;
            }
        }
        return 0;
    }
}

// Forward declaration for the full variant (subpixel offset + font smoothing)
int coretext_rasterize_glyph_ex(
    void* font_ptr, unsigned int glyph_index, float scale_factor,
    float subpixel_offset_x, float subpixel_offset_y, int smooth_fonts,
    unsigned char** out_pixels, unsigned int* out_width, unsigned int* out_height,
    int* out_bearing_x, int* out_bearing_y, int* out_advance, int* out_is_color);

/// Rasterize a glyph to a grayscale bitmap
/// Returns 0 on success, -1 on failure
/// out_pixels is allocated by this function, caller must free with coretext_free_bitmap
int coretext_rasterize_glyph(
    void* font_ptr,
    unsigned int glyph_index,
    float scale_factor,
    unsigned char** out_pixels,
    unsigned int* out_width,
    unsigned int* out_height,
    int* out_bearing_x,
    int* out_bearing_y,
    int* out_advance,
    int* out_is_color
) {
    // Default subpixel offset: 0
    return coretext_rasterize_glyph_ex(font_ptr, glyph_index, scale_factor,
        0.0f, 0.0f, 1, out_pixels, out_width, out_height, out_bearing_x, out_bearing_y,
        out_advance, out_is_color);
}

/// Rasterize glyph with subpixel offset (R6: subpixel variants).
/// subpixel_offset_x/y: offset within physical pixel [0.0, 1.0)
int coretext_rasterize_glyph_subpixel(
    void* font_ptr, unsigned int glyph_index, float scale_factor,
    float subpixel_offset_x, float subpixel_offset_y,
    unsigned char** out_pixels, unsigned int* out_width, unsigned int* out_height,
    int* out_bearing_x, int* out_bearing_y, int* out_advance, int* out_is_color
) {
    return coretext_rasterize_glyph_ex(font_ptr, glyph_index, scale_factor,
        subpixel_offset_x, subpixel_offset_y, 1, out_pixels, out_width, out_height,
        out_bearing_x, out_bearing_y, out_advance, out_is_color);
}

/// Rasterize a glyph with a subpixel offset; smooth_fonts = 0 draws without platform font
/// smoothing (macOS stem darkening; iOS draws glyphs unsmoothed).
int coretext_rasterize_glyph_ex(
    void* font_ptr,
    unsigned int glyph_index,
    float scale_factor,
    float subpixel_offset_x,
    float subpixel_offset_y,
    int smooth_fonts,
    unsigned char** out_pixels,
    unsigned int* out_width,
    unsigned int* out_height,
    int* out_bearing_x,
    int* out_bearing_y,
    int* out_advance,
    int* out_is_color
) {
    @autoreleasepool {
        CTFontRef font = (CTFontRef)font_ptr;
        CGGlyph glyph = (CGGlyph)glyph_index;
        if (out_is_color) *out_is_color = 0;
        float scale = (scale_factor > 0) ? scale_factor : 1.0f;

        // Get glyph bounding rect (logical pixels)
        CGRect bbox = CTFontGetBoundingRectsForGlyphs(font, kCTFontOrientationDefault, &glyph, NULL, 1);

        // Get advance (logical pixels — unchanged)
        CGSize advanceSize;
        CTFontGetAdvancesForGlyphs(font, kCTFontOrientationDefault, &glyph, &advanceSize, 1);

        *out_advance = (int)ceil(advanceSize.width);

        // Invalid bbox (NaN from Variable Font .notdef glyph)
        if (isnan(bbox.size.width) || isnan(bbox.size.height) ||
            isnan(bbox.origin.x) || isnan(bbox.origin.y)) {
            *out_pixels = NULL;
            *out_width = 0;
            *out_height = 0;
            *out_bearing_x = 0;
            *out_bearing_y = 0;
            return 0;
        }

        // Empty glyph (e.g., space) — use <= 0 threshold to avoid filtering narrow glyphs like 'i', 'l'
        if (bbox.size.width <= 0 || bbox.size.height <= 0) {
            *out_pixels = NULL;
            *out_width = 0;
            *out_height = 0;
            *out_bearing_x = 0;
            *out_bearing_y = 0;
            return 0;
        }

        // Calculate bitmap dimensions in physical pixels with padding.
        // R6: subpixel offset affects floor/ceil of origin calculation
        const float origin_x_px = (float)bbox.origin.x * scale + subpixel_offset_x;
        const float origin_y_px = (float)bbox.origin.y * scale + subpixel_offset_y;
        const float origin_x_px_floor = floor(origin_x_px);
        const float origin_y_px_floor = floor(origin_y_px);

        // Subpixel offset can make glyph 1 pixel wider/taller than original
        unsigned int width = (unsigned int)ceil(bbox.size.width * scale + subpixel_offset_x) + 2;
        unsigned int height = (unsigned int)ceil(bbox.size.height * scale + subpixel_offset_y) + 2;

        *out_width = width;
        *out_height = height;
        // Bearings are in physical pixels (match bitmap + 1px padding)
        *out_bearing_x = (int)origin_x_px_floor - 1;
        // bearing_y = height - baseline_y; baseline_y = 1 - origin_y_px_floor
        *out_bearing_y = (int)height - 1 + (int)origin_y_px_floor;

        // Color glyphs use BGRA premultiplied context: DeviceGray + AlphaNone only
        // preserves coverage; color is lost at rasterization, unrecoverable by shader.
        const int is_color = coretext_font_has_color_glyphs(font_ptr);
        if (out_is_color) *out_is_color = is_color;

        const unsigned int bytes_per_pixel = is_color ? 4u : 1u;
        const unsigned int bytes_per_row = width * bytes_per_pixel;

        // Allocate pixel buffer (physical pixels)
        unsigned char* pixels = (unsigned char*)calloc(width * height, bytes_per_pixel);
        if (!pixels) {
            return -1;
        }

        // Create bitmap context at physical pixel size
        CGColorSpaceRef colorSpace = is_color ? CGColorSpaceCreateDeviceRGB()
                                              : CGColorSpaceCreateDeviceGray();
        // BGRA8Unorm texture in little-endian: kCGImageAlphaPremultipliedFirst |
        // kCGBitmapByteOrder32Little (memory order B,G,R,A).
        const CGBitmapInfo bitmap_info = is_color
            ? (CGBitmapInfo)(kCGImageAlphaPremultipliedFirst | kCGBitmapByteOrder32Little)
            : (CGBitmapInfo)kCGImageAlphaNone;
        CGContextRef ctx = CGBitmapContextCreate(
            pixels,
            width,
            height,
            8,              // bits per component
            bytes_per_row,
            colorSpace,
            bitmap_info
        );
        CGColorSpaceRelease(colorSpace);

        if (!ctx) {
            free(pixels);
            return -1;
        }

        // Scale context so CoreText renders at physical resolution
        CGContextScaleCTM(ctx, scale, scale);

        // Set up context for rendering. Color glyphs self-color (sbix/COLR);
        // don't need or apply fill color.
        if (!is_color) {
            CGContextSetGrayFillColor(ctx, 1.0, 1.0);
        }
        CGContextSetAllowsAntialiasing(ctx, true);
        CGContextSetShouldAntialias(ctx, true);
        // Keep glyph edges smooth, avoid fuzziness in small sizes/CJK.
        CGContextSetAllowsFontSmoothing(ctx, smooth_fonts != 0);
        CGContextSetShouldSmoothFonts(ctx, smooth_fonts != 0);
        CGContextSetAllowsFontSubpixelPositioning(ctx, true);
        CGContextSetShouldSubpixelPositionFonts(ctx, true);
        // Disable quantization for stable detail with atlas subpixel variants.
        CGContextSetAllowsFontSubpixelQuantization(ctx, false);
        CGContextSetShouldSubpixelQuantizeFonts(ctx, false);

        // Position glyph (in logical coordinates; CTM handles scaling).
        // R6: subpixel offset passed via precise positioning to CoreText
        CGPoint position = CGPointMake(
            (-origin_x_px_floor + 1.0f) / scale,
            (-origin_y_px_floor + 1.0f) / scale
        );

        // Draw glyph
        CTFontDrawGlyphs(font, &glyph, &position, 1, ctx);

        CGContextRelease(ctx);

        *out_pixels = pixels;
        return 0;
    }
}

/// Free bitmap allocated by coretext_rasterize_glyph
void coretext_free_bitmap(unsigned char* pixels) {
    if (pixels) {
        free(pixels);
    }
}

// ============================================================================
// Text Shaping
// ============================================================================

/// Shaped glyph result (C struct)
typedef struct {
    unsigned int glyph_index;
    unsigned int cluster;
    float x_advance;
    float y_advance;
    float x_offset;
    float y_offset;
    unsigned int is_synthetic_italic; // 1 if this glyph needs synthetic italic skew at render time
    unsigned int is_fallback_font;    // 1 if this glyph uses a fallback font (e.g. CJK)
    void* fallback_font_ref;          // retained CTFontRef of the actual fallback font (NULL if not fallback)
} CoreTextShapedGlyph;

typedef struct {
    unsigned int byte_offset;
    float primary_x;
    float secondary_x;
    unsigned int has_secondary;
} CoreTextCaretStop;

typedef struct {
    float width;
    float ascent;
    float descent;
    float leading;
    unsigned int base_rtl;
} CoreTextLineMetrics;

// Decode one UTF-8/WTF-8 storage sequence. Surrogates are accepted; all
// other UTF-8 restrictions still apply. Mapping uses original storage bytes,
// not re-encoding NSString (which would lose isolated surrogate identities).
static bool zenitCTDecodeStorage(const char *bytes, NSUInteger len, NSUInteger *offset, uint32_t *cp) {
    if (*offset >= len) return false;
    const unsigned char *b = (const unsigned char *)bytes + *offset;
    unsigned int n;
    uint32_t value;
    if (b[0] < 0x80) { n = 1; value = b[0]; }
    else if (b[0] >= 0xC2 && b[0] <= 0xDF) { n = 2; value = b[0] & 0x1F; }
    else if (b[0] >= 0xE0 && b[0] <= 0xEF) { n = 3; value = b[0] & 0x0F; }
    else if (b[0] >= 0xF0 && b[0] <= 0xF4) { n = 4; value = b[0] & 7; }
    else return false;
    if (n > len - *offset) return false;
    for (unsigned int i = 1; i < n; i++) {
        if ((b[i] & 0xC0) != 0x80) return false;
        value = (value << 6) | (b[i] & 0x3F);
    }
    if ((n == 2 && value < 0x80) || (n == 3 && value < 0x800) ||
        (n == 4 && (value < 0x10000 || value > 0x10FFFF))) return false;
    *offset += n;
    *cp = value;
    return true;
}

static NSString *zenitCTStringFromUTF8(const char *bytes, NSUInteger len) {
    NSString *s = [[NSString alloc] initWithBytes:bytes length:len encoding:NSUTF8StringEncoding];
    const bool startsBOM = len >= 3 && (unsigned char)bytes[0] == 0xEF &&
        (unsigned char)bytes[1] == 0xBB && (unsigned char)bytes[2] == 0xBF;
    // Parse leading BOMs ourselves: Foundation can strip one, and checking
    // the first resulting character cannot distinguish repeated BOMs.
    if (s && !startsBOM) return s;
    if (len > SIZE_MAX / sizeof(unichar)) return nil;
    unichar *units = malloc(len * sizeof(unichar));
    if (!units) return nil;
    NSUInteger offset = 0, count = 0;
    while (offset < len) {
        uint32_t cp;
        if (!zenitCTDecodeStorage(bytes, len, &offset, &cp)) { free(units); return nil; }
        if (cp <= 0xFFFF) units[count++] = (unichar)cp;
        else {
            units[count++] = (unichar)(0xD800 + ((cp - 0x10000) >> 10));
            units[count++] = (unichar)(0xDC00 + ((cp - 0x10000) & 0x3FF));
        }
    }
    // Rendering replaces only unpaired units. Preserve unit count so the
    // original storage-byte maps remain valid; adjacent halves render as a pair.
    for (NSUInteger i = 0; i < count; i++) {
        if (units[i] >= 0xD800 && units[i] <= 0xDBFF && i + 1 < count &&
            units[i + 1] >= 0xDC00 && units[i + 1] <= 0xDFFF) { i++; continue; }
        if (units[i] >= 0xD800 && units[i] <= 0xDFFF) units[i] = 0xFFFD;
    }
    s = [[NSString alloc] initWithCharacters:units length:count];
    free(units);
    return s;
}

/// Extract CTLine caret offsets for UTF-8 grapheme boundaries supplied by the
/// framework. CoreText remains the authority for bidi visual placement and
/// ligature geometry; Unicode grapheme segmentation remains framework-owned.
int coretext_line_caret_stops(
    void* font_ptr,
    const char* text,
    unsigned int text_len,
    const unsigned int* boundaries,
    unsigned int boundary_count,
    CoreTextCaretStop* out_stops,
    CoreTextLineMetrics* out_metrics
) {
    @autoreleasepool {
        if (!font_ptr || !text || !boundaries || !out_stops || !out_metrics || boundary_count == 0) {
            return -1;
        }

        NSString *nsText = zenitCTStringFromUTF8(text, text_len);
        if (!nsText) return -1;
        NSAttributedString *attr = createAttributedStringWithPreferredSymbolFallback(nsText, (CTFontRef)font_ptr);
        CTLineRef line = CTLineCreateWithAttributedString((__bridge CFAttributedStringRef)attr);
        if (!line) return -1;

        CGFloat ascent = 0;
        CGFloat descent = 0;
        CGFloat leading = 0;
        const double width = CTLineGetTypographicBounds(line, &ascent, &descent, &leading);
        out_metrics->width = (float)width;
        out_metrics->ascent = (float)ascent;
        out_metrics->descent = (float)descent;
        out_metrics->leading = (float)leading;
        out_metrics->base_rtl = 0;
        CFArrayRef runs = CTLineGetGlyphRuns(line);
        if (CFArrayGetCount(runs) > 0) {
            CTRunRef first_run = (CTRunRef)CFArrayGetValueAtIndex(runs, 0);
            out_metrics->base_rtl = (CTRunGetStatus(first_run) & kCTRunStatusRightToLeft) ? 1u : 0u;
        }

        // Only scalar/grapheme boundaries are queried, so recording the UTF-8 byte
        // position at each UTF-16 scalar start plus the final sentinel is enough.
        unsigned int *utf8_to_utf16 = (unsigned int *)malloc((text_len + 1) * sizeof(unsigned int));
        if (!utf8_to_utf16) {
            CFRelease(line);
            return -1;
        }
        for (unsigned int i = 0; i <= text_len; i++) utf8_to_utf16[i] = UINT_MAX;
        NSUInteger byte = 0;
        unsigned int wide = 0;
        while (byte < text_len) {
            utf8_to_utf16[byte] = wide;
            uint32_t cp;
            if (!zenitCTDecodeStorage(text, text_len, &byte, &cp)) {
                free(utf8_to_utf16); CFRelease(line); return -1;
            }
            wide += cp > 0xFFFF ? 2 : 1;
        }
        utf8_to_utf16[text_len] = wide;

        for (unsigned int i = 0; i < boundary_count; i++) {
            const unsigned int byte = boundaries[i];
            if (byte > text_len || utf8_to_utf16[byte] == UINT_MAX) {
                free(utf8_to_utf16);
                CFRelease(line);
                return -1;
            }
            CGFloat secondary = 0;
            const CGFloat primary = CTLineGetOffsetForStringIndex(line, utf8_to_utf16[byte], &secondary);
            out_stops[i].byte_offset = byte;
            out_stops[i].primary_x = (float)primary;
            out_stops[i].secondary_x = (float)secondary;
            out_stops[i].has_secondary = fabs(primary - secondary) > 0.01 ? 1u : 0u;
        }

        free(utf8_to_utf16);
        CFRelease(line);
        return 0;
    }
}

/// Shape text using CoreText
/// Returns number of glyphs, or -1 on error
/// out_glyphs is allocated by this function, caller must free with coretext_free_shaped_glyphs
int coretext_shape_text(
    void* font_ptr,
    const char* text,
    unsigned int text_len,
    CoreTextShapedGlyph** out_glyphs,
    unsigned int* out_count,
    int synthetic_italic
) {
    @autoreleasepool {
        CTFontRef font = (CTFontRef)font_ptr;

        // Create attributed string
        NSString *nsText = zenitCTStringFromUTF8(text, text_len);
        if (!nsText) {
            *out_glyphs = NULL;
            *out_count = 0;
            return -1;
        }

        NSAttributedString *attrStr = createAttributedStringWithPreferredSymbolFallback(nsText, font);

        // Create line and get glyph runs
        CTLineRef line = CTLineCreateWithAttributedString((__bridge CFAttributedStringRef)attrStr);
        CFArrayRef runs = CTLineGetGlyphRuns(line);
        CFIndex runCount = CFArrayGetCount(runs);

        // Count total glyphs across all runs
        unsigned int totalGlyphs = 0;
        CGFontRef baseCgFont = CTFontCopyGraphicsFont(font, NULL);
        for (CFIndex r = 0; r < runCount; r++) {
            CTRunRef run = (CTRunRef)CFArrayGetValueAtIndex(runs, r);
            totalGlyphs += (unsigned int)CTRunGetGlyphCount(run);
        }

        if (totalGlyphs == 0) {
            CFRelease(line);
            if (baseCgFont) CFRelease(baseCgFont);
            *out_glyphs = NULL;
            *out_count = 0;
            return 0;
        }

        // Allocate output
        CoreTextShapedGlyph* glyphs = (CoreTextShapedGlyph*)malloc(totalGlyphs * sizeof(CoreTextShapedGlyph));
        if (!glyphs) {
            CFRelease(line);
            if (baseCgFont) CFRelease(baseCgFont);
            return -1;
        }

        // Map original storage bytes, including six-byte surrogate pairs
        // created at edit seams. Both units of a four-byte scalar map to its start.
        NSUInteger utf16Len = nsText.length;
        unsigned int* utf16ToUtf8 = calloc(utf16Len + 1, sizeof(unsigned int));
        if (!utf16ToUtf8) {
            free(glyphs); CFRelease(line); if (baseCgFont) CFRelease(baseCgFont);
            return -1;
        }
        NSUInteger byte = 0, wide = 0;
        while (byte < text_len) {
            const unsigned int start = (unsigned int)byte;
            uint32_t cp;
            if (!zenitCTDecodeStorage(text, text_len, &byte, &cp)) {
                free(utf16ToUtf8); free(glyphs); CFRelease(line);
                if (baseCgFont) CFRelease(baseCgFont);
                return -1;
            }
            utf16ToUtf8[wide++] = start;
            if (cp > 0xFFFF) utf16ToUtf8[wide++] = start;
        }
        utf16ToUtf8[wide] = text_len;

        // Extract glyph info from all runs
        unsigned int glyphIdx = 0;
        float pen_x = 0.0f;
        for (CFIndex r = 0; r < runCount; r++) {
            CTRunRef run = (CTRunRef)CFArrayGetValueAtIndex(runs, r);
            CFIndex count = CTRunGetGlyphCount(run);

            // Check if this run uses a fallback font (e.g. CJK characters)
            // and if it needs synthetic italic
            CFDictionaryRef runAttrs = CTRunGetAttributes(run);
            CTFontRef runFont = (CTFontRef)CFDictionaryGetValue(runAttrs, kCTFontAttributeName);
            int isFallbackFont = 0;
            if (runFont) {
                // Don't use raw pointer inequality here:
                // CT may materialize equivalent CTFont instances per run,
                // especially after deriving fonts at fractional sizes.
                if (!CFEqual(runFont, font)) {
                    // Additional guard: equivalent CTFont instances can still be
                    // backed by the same CGFont. Treat them as non-fallback.
                    CGFontRef runCgFont = CTFontCopyGraphicsFont(runFont, NULL);
                    int sameBackingFont = (runCgFont && baseCgFont && CFEqual(runCgFont, baseCgFont)) ? 1 : 0;
                    if (runCgFont) CFRelease(runCgFont);
                    isFallbackFont = sameBackingFont ? 0 : 1;
                }
            }
            int needsSyntheticItalic = 0;
            if (synthetic_italic && isFallbackFont && runFont) {
                // Check fallback fonts (e.g., CJK fallback to PingFang SC) for synthetic italic.
                // Primary font (e.g., Inter-Italic VF) already has italic glyphs; don't skew.
                CTFontSymbolicTraits runTraits = CTFontGetSymbolicTraits(runFont);
                if (!(runTraits & kCTFontItalicTrait)) {
                    needsSyntheticItalic = 1;
                }
            }

            // Get glyph IDs
            CGGlyph* runGlyphs = (CGGlyph*)malloc(count * sizeof(CGGlyph));
            CTRunGetGlyphs(run, CFRangeMake(0, count), runGlyphs);

            // Get positions
            CGPoint* positions = (CGPoint*)malloc(count * sizeof(CGPoint));
            CTRunGetPositions(run, CFRangeMake(0, count), positions);

            // Get advances
            CGSize* advances = (CGSize*)malloc(count * sizeof(CGSize));
            CTRunGetAdvances(run, CFRangeMake(0, count), advances);

            // Get string indices (for cluster mapping)
            CFIndex* indices = (CFIndex*)malloc(count * sizeof(CFIndex));
            CTRunGetStringIndices(run, CFRangeMake(0, count), indices);

            for (CFIndex i = 0; i < count && glyphIdx < totalGlyphs; i++) {
                glyphs[glyphIdx].glyph_index = (unsigned int)runGlyphs[i];

                // Map UTF-16 string index to UTF-8 byte offset
                CFIndex utf16Idx = indices[i];
                if (utf16ToUtf8 && utf16Idx >= 0 && (NSUInteger)utf16Idx < utf16Len) {
                    glyphs[glyphIdx].cluster = utf16ToUtf8[utf16Idx];
                } else {
                    glyphs[glyphIdx].cluster = (unsigned int)utf16Idx;
                }

                glyphs[glyphIdx].x_advance = (float)advances[i].width;
                glyphs[glyphIdx].y_advance = (float)advances[i].height;
                // Convert absolute CoreText positions to relative offsets from current pen
                glyphs[glyphIdx].x_offset = (float)positions[i].x - pen_x;
                glyphs[glyphIdx].y_offset = (float)positions[i].y;
                glyphs[glyphIdx].is_synthetic_italic = needsSyntheticItalic ? 1 : 0;
                glyphs[glyphIdx].is_fallback_font = isFallbackFont ? 1 : 0;
                // Retain the fallback font ref so it survives CTLine release.
                // Caller is responsible for releasing via the returned ref.
                if (isFallbackFont && runFont) {
                    CFRetain(runFont);
                    glyphs[glyphIdx].fallback_font_ref = (void*)runFont;
                } else {
                    glyphs[glyphIdx].fallback_font_ref = NULL;
                }
                glyphIdx++;
                pen_x += (float)advances[i].width;
            }

            free(runGlyphs);
            free(positions);
            free(advances);
            free(indices);
        }
        if (baseCgFont) CFRelease(baseCgFont);

        if (utf16ToUtf8) free(utf16ToUtf8);
        CFRelease(line);

        *out_glyphs = glyphs;
        *out_count = glyphIdx;
        return 0;
    }
}

/// Free shaped glyphs allocated by coretext_shape_text.
/// fallback_font_ref ownership is transferred to the caller — this function does NOT release them.
void coretext_free_shaped_glyphs(CoreTextShapedGlyph* glyphs) {
    if (glyphs) {
        free(glyphs);
    }
}

// Font enumeration (font selector).
//
// Design constraints: 272 families / 990 faces enumerate in 17.6ms, full trait scan 40.1ms,
// so the host scans once in the background with no caching. 17% of families can't render
// their own name (Arabic/Hebrew/Devanagari/CJK...), so both can_render_name and lang must be
// provided for UI sample switching. Symbolic fonts (Wingdings) have Latin glyphs but render
// as pictographs; glyph coverage can't detect this, only symbolic class == 12 is reliable.

/// Family count; host allocates array from this.
int coretext_family_count(void) {
    @autoreleasepool {
        NSArray *fams = (__bridge_transfer NSArray *)CTFontManagerCopyAvailableFontFamilyNames();
        return (int)fams.count;
    }
}

/// Copy family names into out_names[0..max), return count written.
/// Each must be freed with coretext_free_c_string.
int coretext_copy_family_names(char **out_names, int max) {
    if (!out_names || max <= 0) return 0;
    @autoreleasepool {
        NSArray *fams = (__bridge_transfer NSArray *)CTFontManagerCopyAvailableFontFamilyNames();
        int n = 0;
        for (NSString *fam in fams) {
            if (n >= max) break;
            const char *utf8 = fam.UTF8String;
            if (!utf8) continue;
            size_t len = strlen(utf8);
            char *copy = (char *)malloc(len + 1);
            if (!copy) continue;
            memcpy(copy, utf8, len + 1);
            out_names[n++] = copy;
        }
        return n;
    }
}

typedef struct {
    int  is_symbolic; // symbolic class == 12: name can't be rendered by self (Wingdings, etc.)
    int  can_render_name; // Font has all glyphs needed to render its own name
    int  is_variable; // Has variation axes
    int  face_count; // Face count in this family
    int  classification; // See enum below
    int  has_latin; // Has basic Latin glyphs ('A' 'a' 'g' '1')
    char lang[16]; // CTFontCopySupportedLanguages()[0]; use for sample string selection
} CoreTextFamilyInfo;

// classification values (aligned with CTFontStylisticClass, coarsened for UI)
enum {
    CT_CLASS_UNKNOWN    = 0,
    CT_CLASS_SERIF      = 1,
    CT_CLASS_SANS       = 2,
    CT_CLASS_SCRIPT     = 3,
    CT_CLASS_DISPLAY    = 4,
    CT_CLASS_MONOSPACE  = 5,
    CT_CLASS_SYMBOLIC   = 6,
};

static int classifyFromTraits(CTFontSymbolicTraits traits) {
    if (traits & kCTFontTraitMonoSpace) return CT_CLASS_MONOSPACE;
    // WARNING: kCTFontClass* constants are already-positioned mask values (e.g.,
    // Symbolic = 0xC0000000), not shifted ordinals. Comparing shifted values to these
    // constants always fails -- first version did this, 0/272 symbolic detected, wrong
    // Helvetica Neue class. Compare against masked value.
    CTFontSymbolicTraits cls = traits & kCTFontClassMaskTrait;
    switch (cls) {
        case kCTFontClassOldStyleSerifs:
        case kCTFontClassTransitionalSerifs:
        case kCTFontClassModernSerifs:
        case kCTFontClassClarendonSerifs:
        case kCTFontClassSlabSerifs:
        case kCTFontClassFreeformSerifs:
            return CT_CLASS_SERIF;
        case kCTFontClassSansSerif:
            return CT_CLASS_SANS;
        case kCTFontClassScripts:
            return CT_CLASS_SCRIPT;
        case kCTFontClassOrnamentals:
            return CT_CLASS_DISPLAY;
        case kCTFontClassSymbolic:
            return CT_CLASS_SYMBOLIC;
        default:
            return CT_CLASS_UNKNOWN;
    }
}

/// Family can render its own name. WARNING: glyph coverage can't detect symbolic
/// fonts -- Wingdings returns true for 'A'/'a' but draws pictographs. Use
/// is_symbolic separately.
static int familyCanRenderOwnName(CTFontRef font, NSString *name) {
    NSUInteger len = name.length;
    if (len == 0) return 1;
    if (len > 256) len = 256;
    unichar chars[256];
    [name getCharacters:chars range:NSMakeRange(0, len)];
    CGGlyph glyphs[256];
    return CTFontGetGlyphsForCharacters(font, chars, glyphs, len) ? 1 : 0;
}

/// Face count in family. SF Pro and system fonts return 0 via descriptor query.
static int familyFaceCount(NSString *family) {
    NSDictionary *attrs = @{ (id)kCTFontFamilyNameAttribute : family };
    CTFontDescriptorRef desc =
        CTFontDescriptorCreateWithAttributes((__bridge CFDictionaryRef)attrs);
    if (!desc) return 0;
    NSSet *keys = [NSSet setWithObject:(id)kCTFontFamilyNameAttribute];
    NSArray *matches = (__bridge_transfer NSArray *)
        CTFontDescriptorCreateMatchingFontDescriptors(desc, (__bridge CFSetRef)keys);
    CFRelease(desc);
    return (int)matches.count;
}

/// Get all picker metadata at once; avoid multiple language crossings.
/// Return 0 success, -1 failure (family not buildable).
int coretext_family_info(const char *family, CoreTextFamilyInfo *out) {
    if (!family || !out) return -1;
    @autoreleasepool {
        NSString *fam = [NSString stringWithUTF8String:family];
        if (!fam) return -1;
        CTFontRef font = CTFontCreateWithName((__bridge CFStringRef)fam, 24.0, NULL);
        if (!font) return -1;

        memset(out, 0, sizeof(*out));

        CTFontSymbolicTraits traits = CTFontGetSymbolicTraits(font);
        // Compare against masked original value, don't shift.
        out->is_symbolic =
            ((traits & kCTFontClassMaskTrait) == kCTFontClassSymbolic) ? 1 : 0;
        out->classification  = classifyFromTraits(traits);
        out->can_render_name = familyCanRenderOwnName(font, fam);
        {
            // "Can print English?" -- need Latin letters + digits. Without them,
            // ASCII input gets blanks/tofu, UI shows disabled.
            unichar probe[4] = { 'A', 'a', 'g', '1' };
            CGGlyph pg[4];
            out->has_latin = CTFontGetGlyphsForCharacters(font, probe, pg, 4) ? 1 : 0;
        }
        out->face_count      = familyFaceCount(fam);

        NSArray *axes = (__bridge_transfer NSArray *)CTFontCopyVariationAxes(font);
        out->is_variable = (axes.count > 0) ? 1 : 0;

        NSArray *langs = (__bridge_transfer NSArray *)CTFontCopySupportedLanguages(font);
        if (langs.count > 0) {
            const char *tag = [(NSString *)langs[0] UTF8String];
            if (tag) {
                strncpy(out->lang, tag, sizeof(out->lang) - 1);
                out->lang[sizeof(out->lang) - 1] = '\0';
            }
        }

        CFRelease(font);
        return 0;
    }
}

/// Convert CoreText weight trait (-1.0~1.0) to CSS weight (100~900).
/// Inverse of createFontWithWeight table. Take nearest tier, no interpolation:
/// CT scale is discrete anchors; interpolation produces out-of-range values.
static int ctWeightToCss(CGFloat w) {
    static const struct { CGFloat ct; int css; } table[] = {
        { -0.80, 100 }, { -0.60, 200 }, { -0.40, 300 }, { 0.00, 400 },
        {  0.23, 500 }, {  0.30, 600 }, {  0.40, 700 }, {  0.56, 800 },
        {  0.62, 900 },
    };
    int best = 400;
    CGFloat best_d = 1e9;
    for (size_t i = 0; i < sizeof(table)/sizeof(table[0]); i++) {
        CGFloat d = fabs(w - table[i].ct);
        if (d < best_d) { best_d = d; best = table[i].css; }
    }
    return best;
}

/// Enumerate the weight tiers that actually exist in this family. WARNING: CoreText silently
/// downgrades unavailable weights without error (Zapfino has 1 face, Bold returns Regular;
/// Menlo Light returns Regular), so a UI offering non-existent tiers shows no change and
/// no failure signal. Output is sorted ascending by CSS weight and deduplicated (italic is a
/// separate axis). Variable fonts have a continuous axis range, not discrete faces; standard
/// tiers are filled from the axis min/max. Returns the count written; out_weights gets CSS values.
int coretext_family_weights(const char *family, int *out_weights, int max) {
    if (!family || !out_weights || max <= 0) return 0;
    @autoreleasepool {
        NSString *fam = [NSString stringWithUTF8String:family];
        if (!fam) return 0;

        int seen[16]; int n = 0;

        // Variable font: fill standard tiers from Weight axis range.
        CTFontRef probe = CTFontCreateWithName((__bridge CFStringRef)fam, 16, NULL);
        if (probe) {
            NSArray *axes = (__bridge_transfer NSArray *)CTFontCopyVariationAxes(probe);
            CFRelease(probe);
            for (NSDictionary *a in axes) {
                NSNumber *aid = a[(id)kCTFontVariationAxisIdentifierKey];
                if (!aid || aid.unsignedIntValue != 0x77676874) continue; // 'wght'
                int lo = [a[(id)kCTFontVariationAxisMinimumValueKey] intValue];
                int hi = [a[(id)kCTFontVariationAxisMaximumValueKey] intValue];
                for (int w = 100; w <= 900; w += 100) {
                    if (w < lo || w > hi) continue;
                    if (n < max && n < (int)(sizeof(seen)/sizeof(seen[0]))) out_weights[n] = w, seen[n] = w, n++;
                }
                if (n > 0) return n;
            }
        }

        NSDictionary *attrs = @{ (id)kCTFontFamilyNameAttribute : fam };
        CTFontDescriptorRef desc =
            CTFontDescriptorCreateWithAttributes((__bridge CFDictionaryRef)attrs);
        if (!desc) return 0;
        NSSet *keys = [NSSet setWithObject:(id)kCTFontFamilyNameAttribute];
        NSArray *matches = (__bridge_transfer NSArray *)
            CTFontDescriptorCreateMatchingFontDescriptors(desc, (__bridge CFSetRef)keys);
        CFRelease(desc);

        for (id m in matches) {
            NSDictionary *tr = (__bridge_transfer NSDictionary *)
                CTFontDescriptorCopyAttribute((__bridge CTFontDescriptorRef)m,
                                              kCTFontTraitsAttribute);
            if (!tr) continue;
            NSNumber *wn = tr[(id)kCTFontWeightTrait];
            if (!wn) continue;
            int css = ctWeightToCss([wn doubleValue]);
            int dup = 0;
            for (int i = 0; i < n; i++) if (seen[i] == css) { dup = 1; break; }
            if (dup) continue;
            if (n >= max || n >= (int)(sizeof(seen)/sizeof(seen[0]))) break;
            seen[n] = css;
            out_weights[n] = css;
            n++;
        }

        // Ascending (CoreText returns Regular-first, not weight-ordered)
        for (int i = 1; i < n; i++) {
            int v = out_weights[i], j = i - 1;
            while (j >= 0 && out_weights[j] > v) { out_weights[j+1] = out_weights[j]; j--; }
            out_weights[j+1] = v;
        }
        return n;
    }
}

/// Enumerate this family's style names (Regular/Bold Italic/Semibold...).
/// Return count written; each freed with coretext_free_c_string.
int coretext_family_styles(const char *family, char **out_styles, int max) {
    if (!family || !out_styles || max <= 0) return 0;
    @autoreleasepool {
        NSString *fam = [NSString stringWithUTF8String:family];
        if (!fam) return 0;
        NSDictionary *attrs = @{ (id)kCTFontFamilyNameAttribute : fam };
        CTFontDescriptorRef desc =
            CTFontDescriptorCreateWithAttributes((__bridge CFDictionaryRef)attrs);
        if (!desc) return 0;
        NSSet *keys = [NSSet setWithObject:(id)kCTFontFamilyNameAttribute];
        NSArray *matches = (__bridge_transfer NSArray *)
            CTFontDescriptorCreateMatchingFontDescriptors(desc, (__bridge CFSetRef)keys);
        CFRelease(desc);

        int n = 0;
        for (id m in matches) {
            if (n >= max) break;
            NSString *style = (__bridge_transfer NSString *)
                CTFontDescriptorCopyAttribute((__bridge CTFontDescriptorRef)m,
                                              kCTFontStyleNameAttribute);
            if (!style) continue;
            const char *utf8 = style.UTF8String;
            if (!utf8) continue;
            size_t len = strlen(utf8);
            char *copy = (char *)malloc(len + 1);
            if (!copy) continue;
            memcpy(copy, utf8, len + 1);
            out_styles[n++] = copy;
        }
        return n;
    }
}

/// Take first `max_cp` renderable codepoints from font's character set, write as
/// UTF-8. Last-resort sample when lang is empty and not symbolic (real fonts like
/// Noto Sans Batak/Tagalog can't render their name and have no tag). Ask font
/// "what can you draw?". Return codepoint count; 0 = extraction failed.
int coretext_family_sample_codepoints(const char *family, uint32_t *out_cps, int max_cp) {
    if (!family || !out_cps || max_cp <= 0) return 0;
    @autoreleasepool {
        NSString *fam = [NSString stringWithUTF8String:family];
        if (!fam) return 0;
        CTFontRef font = CTFontCreateWithName((__bridge CFStringRef)fam, 24.0, NULL);
        if (!font) return 0;
        CFCharacterSetRef cs = CTFontCopyCharacterSet(font);
        if (!cs) { CFRelease(font); return 0; }

        int n = 0;
        // Skip ASCII and common punctuation; font's character shows in its script range.
        // Upper bound at BMP end -- above that is emoji/supplemental, not suitable samples.
        for (uint32_t cp = 0x00A1; cp <= 0xFFFF && n < max_cp; cp++) {
            if (CFCharacterSetIsLongCharacterMember(cs, cp)) out_cps[n++] = cp;
        }
        CFRelease(cs);
        CFRelease(font);
        return n;
    }
}

/// Validate that the family truly exists. WARNING: coretext_find_font with a descriptor silently
/// returns a fallback for a non-existent family (only the italic path validates). When the
/// picker resolves a saved family name, cross-check the actual name to tell genuine from
/// "missing" disguised as "ok". Returns 1 = exact match; 0 = doesn't exist or was substituted.
int coretext_family_exists(const char *family) {
    if (!family) return 0;
    @autoreleasepool {
        NSString *want = [NSString stringWithUTF8String:family];
        if (!want) return 0;
        CTFontRef font = CTFontCreateWithName((__bridge CFStringRef)want, 12.0, NULL);
        if (!font) return 0;
        NSString *got = (__bridge_transfer NSString *)CTFontCopyFamilyName(font);
        CFRelease(font);
        return (got && [got isEqualToString:want]) ? 1 : 0;
    }
}
