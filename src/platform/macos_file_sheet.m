#import <Cocoa/Cocoa.h>

@interface ZWFileSheet : NSObject
@property (nonatomic, strong) NSSavePanel *panel;
@property (nonatomic, copy) NSArray<NSURL *> *urls;
@property (nonatomic) BOOL done;
@end
@implementation ZWFileSheet
@end

void *zw_file_sheet_begin(uint32_t window_number, int kind, const char *title,
                         const char *prompt, const char *message, const char *initial) {
    if (!NSThread.isMainThread) return NULL;
    @autoreleasepool {
        NSWindow *window = [NSApp windowWithWindowNumber:window_number];
        if (!window || window.attachedSheet) return NULL;
        NSSavePanel *panel;
        if (kind == 4) {
            panel = [NSSavePanel savePanel];
        } else {
            NSOpenPanel *open = [NSOpenPanel openPanel];
            open.canChooseFiles = kind != 1;
            open.canChooseDirectories = kind == 1 || kind == 2;
            open.allowsMultipleSelection = kind == 3;
            panel = open;
        }
        if (title) panel.title = [NSString stringWithUTF8String:title];
        if (prompt) panel.prompt = [NSString stringWithUTF8String:prompt];
        if (message) panel.message = [NSString stringWithUTF8String:message];
        if (initial) {
            NSString *path = [[NSString stringWithUTF8String:initial] stringByExpandingTildeInPath];
            BOOL directory = NO;
            if (path.length && [[NSFileManager defaultManager] fileExistsAtPath:path isDirectory:&directory]) {
                panel.directoryURL = [NSURL fileURLWithPath:directory ? path : path.stringByDeletingLastPathComponent isDirectory:YES];
                if (!directory) panel.nameFieldStringValue = path.lastPathComponent;
            } else if (kind == 4 && path.length) {
                panel.nameFieldStringValue = path.lastPathComponent;
                if (path.stringByDeletingLastPathComponent.length)
                    panel.directoryURL = [NSURL fileURLWithPath:path.stringByDeletingLastPathComponent isDirectory:YES];
            }
        }
        ZWFileSheet *sheet = [ZWFileSheet new];
        sheet.panel = panel;
        __weak NSSavePanel *weakPanel = panel;
        [panel beginSheetModalForWindow:window completionHandler:^(NSModalResponse response) {
            if (response == NSModalResponseOK) {
                NSSavePanel *selected = weakPanel;
                if ([selected isKindOfClass:NSOpenPanel.class]) sheet.urls = ((NSOpenPanel *)selected).URLs;
                else if (selected.URL) sheet.urls = @[selected.URL];
            }
            sheet.panel = nil;
            sheet.done = YES;
        }];
        return (__bridge_retained void *)sheet;
    }
}

NSInteger zw_file_sheet_count(void *handle) {
    ZWFileSheet *sheet = (__bridge ZWFileSheet *)handle;
    return sheet.done ? (NSInteger)sheet.urls.count : -1;
}

NSInteger zw_file_sheet_path(void *handle, size_t index, char *buffer, size_t capacity) {
    ZWFileSheet *sheet = (__bridge ZWFileSheet *)handle;
    if (index >= sheet.urls.count) return -1;
    const char *path = sheet.urls[index].fileSystemRepresentation;
    if (!path) return -1;
    size_t length = strlen(path);
    if (!length || length >= capacity) return -1;
    memcpy(buffer, path, length + 1);
    return (NSInteger)length;
}

void zw_file_sheet_destroy(void *handle) {
    @autoreleasepool {
        ZWFileSheet *sheet = (__bridge_transfer ZWFileSheet *)handle;
        NSSavePanel *panel = sheet.panel;
        sheet.panel = nil;
        if (panel.sheetParent) [panel.sheetParent endSheet:panel returnCode:NSModalResponseCancel];
    }
}
