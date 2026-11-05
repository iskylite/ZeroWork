#import <Cocoa/Cocoa.h>
#include <string.h>

// One panel accepts either a single image or a directory. The worker validates
// the selected filesystem object and detects its source type after selection.
int zw_pick_background_path(char *buffer, int capacity) {
    @autoreleasepool {
        NSOpenPanel *panel = [NSOpenPanel openPanel];
        panel.title = @"选择背景图片或目录";
        panel.prompt = @"选择";
        panel.message = @"选择一张图片，或选择一个目录用于轮播。";
        panel.canChooseFiles = YES;
        panel.canChooseDirectories = YES;
        panel.allowsMultipleSelection = NO;
        if ([panel runModal] != NSModalResponseOK) return 0;
        const char *path = panel.URL.path.UTF8String;
        if (!path || !buffer || capacity <= 0) return -1;
        size_t length = strlen(path);
        if (length >= (size_t)capacity) return -1;
        memcpy(buffer, path, length + 1);
        return (int)length;
    }
}
