#import <Cocoa/Cocoa.h>

// Deliver each URL separately: paths can contain newlines and must not be split.
int zw_pick_upload_files(const char *initial, void *context,
                         int (*receive)(void *, const char *)) {
    @autoreleasepool {
        NSOpenPanel *panel = [NSOpenPanel openPanel];
        panel.title = @"选择要上传的文件";
        panel.prompt = @"上传";
        panel.canChooseFiles = YES;
        panel.canChooseDirectories = NO;
        panel.allowsMultipleSelection = YES;
        if (initial && initial[0]) {
            NSString *path = [[NSString stringWithUTF8String:initial] stringByExpandingTildeInPath];
            BOOL directory = NO;
            if ([[NSFileManager defaultManager] fileExistsAtPath:path isDirectory:&directory]) {
                panel.directoryURL = [NSURL fileURLWithPath:directory ? path : path.stringByDeletingLastPathComponent];
                if (!directory) panel.nameFieldStringValue = path.lastPathComponent;
            }
        }
        if ([panel runModal] != NSModalResponseOK) return 0;
        for (NSURL *url in panel.URLs) {
            if (!receive(context, url.path.fileSystemRepresentation)) return -1;
        }
        return 1;
    }
}

// A single workspace directory or a local AI attachment.
NSInteger zw_pick_ai_local_path(const char *initial, char *buffer, size_t capacity,
                                int directory) {
    @autoreleasepool {
        NSOpenPanel *panel = [NSOpenPanel openPanel];
        panel.title = directory ? @"选择本地工作区" : @"选择本地文件";
        panel.prompt = @"选择";
        panel.canChooseFiles = !directory;
        panel.canChooseDirectories = !!directory;
        panel.allowsMultipleSelection = NO;
        if (initial && initial[0]) {
            NSString *path = [NSString stringWithUTF8String:initial];
            if (path) panel.directoryURL = [NSURL fileURLWithPath:path isDirectory:YES];
        }
        if ([panel runModal] != NSModalResponseOK) return 0;
        const char *selected = panel.URL.path.fileSystemRepresentation;
        if (!selected || !buffer || !capacity) return -1;
        const size_t len = strlen(selected);
        if (!len || len >= capacity) return -1;
        memcpy(buffer, selected, len + 1);
        return (NSInteger)len;
    }
}
