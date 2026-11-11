#import <AppKit/AppKit.h>
#include <limits.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>

enum NotesClipboardResult {
    notesClipboardEmpty = 0,
    notesClipboardBytes = 1,
    notesClipboardFile = 2,
    notesClipboardTooLarge = -1,
    notesClipboardOutOfMemory = -2,
    notesClipboardInvalidImage = -3,
    notesClipboardInvalidPath = -4,
};

static int copyPayload(const void *source, size_t length, int kind, uint8_t **bytes, size_t *count) {
    uint8_t *copy = malloc(length);
    if (!copy) return notesClipboardOutOfMemory;
    memcpy(copy, source, length);
    *bytes = copy;
    *count = length;
    return kind;
}

static int copyImageItems(NSArray<NSPasteboardItem *> *items, size_t limit, uint8_t **bytes, size_t *count) {
    NSArray<NSPasteboardType> *formats = @[
        NSPasteboardTypePNG, @"public.jpeg", @"public.heic", @"public.heif", NSPasteboardTypeTIFF,
        @"org.webmproject.webp", @"com.microsoft.bmp", @"com.compuserve.gif"
    ];
    BOOL declaredImage = NO;
    for (NSPasteboardItem *item in items) {
        for (NSPasteboardType format in formats) {
            if (![item.types containsObject:format]) continue;
            declaredImage = YES;
            NSData *data = [item dataForType:format];
            if (data.length == 0) continue;
            if (data.length > limit) return notesClipboardTooLarge;
            return copyPayload(data.bytes, data.length, notesClipboardBytes, bytes, count);
        }
    }

    NSSet<NSString *> *extensions = [NSSet setWithArray:@[
        @"png", @"jpg", @"jpeg", @"heic", @"heif", @"tif", @"tiff", @"bmp", @"gif", @"webp"
    ]];
    for (NSPasteboardItem *item in items) {
        NSString *reference = [item stringForType:NSPasteboardTypeFileURL];
        if (reference.length == 0) continue;
        NSURL *url = [NSURL URLWithString:reference];
        if (!url.isFileURL || !url.path.isAbsolutePath || url.hasDirectoryPath) continue;
        if (url.host.length != 0 && [url.host caseInsensitiveCompare:@"localhost"] != NSOrderedSame) continue;
        if (![extensions containsObject:url.pathExtension.lowercaseString]) continue;
        NSString *path = url.path;
        const char *encoded = path.UTF8String;
        size_t length = [path lengthOfBytesUsingEncoding:NSUTF8StringEncoding];
        if (!encoded || length == 0 || length >= PATH_MAX || memchr(encoded, 0, length)) return notesClipboardInvalidPath;
        // Only snapshot the path. The notes worker validates and opens it
        // under the same byte budget as an explicitly selected image file.
        return copyPayload(encoded, length, notesClipboardFile, bytes, count);
    }
    return declaredImage ? notesClipboardInvalidImage : notesClipboardEmpty;
}

int zw_notes_copy_clipboard_image(size_t limit, uint8_t **bytes, size_t *count) {
    @autoreleasepool {
        *bytes = NULL;
        *count = 0;
        return copyImageItems(NSPasteboard.generalPasteboard.pasteboardItems, limit, bytes, count);
    }
}
