#import <Cocoa/Cocoa.h>
#include <string.h>

// The import worker validates SKILL.md, a skill folder, or a collection folder.
// Zero means cancellation; the caller starts no job until a path is returned.
int zw_pick_skill_path(char *buffer, int capacity) {
    @autoreleasepool {
        NSOpenPanel *panel = [NSOpenPanel openPanel];
        panel.title = @"选择技能文件或文件夹";
        panel.prompt = @"添加";
        panel.canChooseFiles = YES;
        panel.canChooseDirectories = YES;
        panel.allowsMultipleSelection = NO;
        if ([panel runModal] != NSModalResponseOK) return 0;
        const char *path = panel.URL.path.fileSystemRepresentation;
        if (!path || !buffer || capacity <= 0) return -1;
        size_t length = strlen(path);
        if (length >= (size_t)capacity) return -1;
        memcpy(buffer, path, length + 1);
        return (int)length;
    }
}
