#include "jpeg.h"
#include <CoreGraphics/CoreGraphics.h>
#include <ImageIO/ImageIO.h>
#include <limits.h>

int zw_rfb_decode_jpeg(const uint8_t *data, size_t size, uint32_t width, uint32_t height,
                       uint8_t *output, size_t output_size) {
    int result = -1;
    if (!width || !height || width > 4096 || height > 2160 || size > LONG_MAX ||
        output_size != (size_t)width * height * 4) return -1;
    CFDataRef bytes = CFDataCreateWithBytesNoCopy(NULL, data, (CFIndex)size, kCFAllocatorNull);
    if (!bytes) return -1;
    const void *keys[] = { kCGImageSourceShouldCache };
    const void *values[] = { kCFBooleanFalse };
    CFDictionaryRef options = CFDictionaryCreate(NULL, keys, values, 1,
        &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
    CGImageSourceRef source = CGImageSourceCreateWithData(bytes, options);
    CFDictionaryRef properties = NULL;
    CGImageRef image = NULL;
    CGColorSpaceRef colour = NULL;
    CGContextRef context = NULL;
    if (!source || !CGImageSourceGetType(source) ||
        !CFEqual(CGImageSourceGetType(source), CFSTR("public.jpeg")) ||
        CGImageSourceGetCount(source) != 1) goto cleanup;
    properties = CGImageSourceCopyPropertiesAtIndex(source, 0, options);
    int64_t source_width = 0, source_height = 0;
    CFNumberRef w = properties ? CFDictionaryGetValue(properties, kCGImagePropertyPixelWidth) : NULL;
    CFNumberRef h = properties ? CFDictionaryGetValue(properties, kCGImagePropertyPixelHeight) : NULL;
    if (!w || !h || CFGetTypeID(w) != CFNumberGetTypeID() || CFGetTypeID(h) != CFNumberGetTypeID() ||
        !CFNumberGetValue(w, kCFNumberSInt64Type, &source_width) ||
        !CFNumberGetValue(h, kCFNumberSInt64Type, &source_height) ||
        source_width != width || source_height != height) goto cleanup;
    image = CGImageSourceCreateImageAtIndex(source, 0, options);
    if (!image || CGImageGetWidth(image) != width || CGImageGetHeight(image) != height) goto cleanup;
    colour = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
    if (!colour) goto cleanup;
    context = CGBitmapContextCreate(output, width, height, 8, (size_t)width * 4, colour,
        kCGImageAlphaPremultipliedLast | kCGBitmapByteOrder32Big);
    if (!context) goto cleanup;
    CGContextSetBlendMode(context, kCGBlendModeCopy);
    CGContextDrawImage(context, CGRectMake(0, 0, width, height), image);
    for (size_t i = 3; i < output_size; i += 4) output[i] = 255;
    result = 0;
cleanup:
    if (context) CGContextRelease(context);
    if (colour) CGColorSpaceRelease(colour);
    if (image) CGImageRelease(image);
    if (properties) CFRelease(properties);
    if (source) CFRelease(source);
    if (options) CFRelease(options);
    CFRelease(bytes);
    return result;
}
