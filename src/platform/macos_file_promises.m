// Native Finder file promises. Main-thread polling keeps all Zig/Zenit work on
// its owner thread. No file URL is published before the real download succeeds.
#import <Cocoa/Cocoa.h>
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>
#include "macos_file_promises.h"
@interface ZWPromisedFile : NSObject <NSFilePromiseProviderDelegate>
@property NSString *name;
@property NSUInteger index;
@property NSURL *destination;
@property BOOL requested;
@property BOOL delivered;
@property BOOL announced;
@property BOOL invalidated;
@property(copy) void (^completion)(NSError *);
@end
@implementation ZWPromisedFile
- (NSString *)filePromiseProvider:(NSFilePromiseProvider *)provider fileNameForType:(NSString *)type { return self.name; }
- (NSOperationQueue *)operationQueueForFilePromiseProvider:(NSFilePromiseProvider *)provider { return NSOperationQueue.mainQueue; }
- (void)filePromiseProvider:(NSFilePromiseProvider *)provider writePromiseToURL:(NSURL *)url completionHandler:(void (^)(NSError *))completion {
    if (self.invalidated || self.requested || !url.isFileURL) { completion([NSError errorWithDomain:@"ZeroWork.FilePromise" code:1 userInfo:@{NSLocalizedDescriptionKey:@"无效或重复的下载目标"}]); return; }
    self.destination = url; self.completion = completion; self.requested = YES;
}
@end
@interface ZWPromiseSession : NSObject <NSDraggingSource>
@property NSArray<ZWPromisedFile *> *files;
@property BOOL ended;
@property BOOL cancelled;
@end
@implementation ZWPromiseSession
- (NSDragOperation)draggingSession:(NSDraggingSession *)session sourceOperationMaskForDraggingContext:(NSDraggingContext)context { return NSDragOperationCopy; }
- (BOOL)ignoreModifierKeysForDraggingSession:(NSDraggingSession *)session { return YES; }
- (void)draggingSession:(NSDraggingSession *)session endedAtPoint:(NSPoint)point operation:(NSDragOperation)operation { self.ended = YES; self.cancelled = operation == NSDragOperationNone; }
@end
static NSMutableDictionary<NSNumber *, ZWPromiseSession *> *sessions;
static uint64_t nextToken = 1;
uint64_t zw_file_promises_begin(uint32_t window_id, const char *const *names, size_t count, float x, float y) {
    if (!NSThread.isMainThread || !names || !count || count > 1024) return 0;
    NSWindow *window = [NSApp windowWithWindowNumber:window_id];
    NSEvent *event = NSApp.currentEvent;
    if (!window || !event || event.window != window || !window.contentView) return 0;
    if (event.type != NSEventTypeLeftMouseDragged && event.type != NSEventTypeLeftMouseDown) return 0;
    NSMutableArray *files = [NSMutableArray arrayWithCapacity:count], *items = [NSMutableArray arrayWithCapacity:count];
    for (size_t i=0;i<count;i++) {
        NSString *name = names[i] ? [NSString stringWithUTF8String:names[i]] : nil;
        if (!name.length || [name containsString:@"/"] || [name isEqualToString:@"."] || [name isEqualToString:@".."]) return 0;
        ZWPromisedFile *file = [ZWPromisedFile new]; file.name=name; file.index=i; [files addObject:file];
        UTType *type = [UTType typeWithFilenameExtension:name.pathExtension];
        NSFilePromiseProvider *provider = [[NSFilePromiseProvider alloc] initWithFileType:(type ?: UTTypeData).identifier delegate:file];
        NSDraggingItem *item = [[NSDraggingItem alloc] initWithPasteboardWriter:provider];
        NSImage *image = [NSWorkspace.sharedWorkspace iconForContentType:type ?: UTTypeData];
        [item setDraggingFrame:NSMakeRect(x+4*i, window.contentView.bounds.size.height-y+4*i, 32, 32) contents:image]; [items addObject:item];
    }
    ZWPromiseSession *session = [ZWPromiseSession new]; session.files=files;
    if (!sessions) sessions=[NSMutableDictionary dictionary];
    uint64_t token = nextToken++; if (!token) return 0;
    sessions[@(token)] = session;
    // Use the genuine current drag event. Zenit releases its internal drag
    // capture at the next safe layout point, after pointer dispatch unwinds.
    NSDraggingSession *drag = [window.contentView beginDraggingSessionWithItems:items event:event source:session];
    if (!drag) { [sessions removeObjectForKey:@(token)]; return 0; }
    drag.animatesToStartingPositionsOnCancelOrFail = YES;
    return token;
}
int zw_file_promises_poll(uint64_t token, uint32_t *index, char *destination, size_t capacity) {
    if (!NSThread.isMainThread) return -1;
    ZWPromiseSession *session=sessions[@(token)]; if (!session) return -1;
    for (ZWPromisedFile *file in session.files) if (file.requested && !file.announced && !file.delivered) {
        const char *path=file.destination.path.fileSystemRepresentation; size_t len=strlen(path);
        if (len+1>capacity) return -1;
        memcpy(destination,path,len+1); *index=(uint32_t)file.index; file.announced=YES; return 1;
    }
    return 0;
}
int zw_file_promises_status(uint64_t token) {
    if (!NSThread.isMainThread) return -1;
    ZWPromiseSession *session=sessions[@(token)]; if (!session) return -1;
    if (session.cancelled) return 2;
    if (session.ended) return 1;
    return 0;
}
int zw_file_promises_complete(uint64_t token, uint32_t index, const char *staged_path) {
    if (!NSThread.isMainThread) return 0;
    ZWPromiseSession *session=sessions[@(token)]; if (!session || index>=session.files.count) return 0;
    ZWPromisedFile *file=session.files[index]; if (!file.requested || file.delivered || !file.completion) return 0;
    void (^completion)(NSError *)=file.completion;
    file.delivered=YES; file.completion=nil;
    if (!staged_path) {
        completion([NSError errorWithDomain:@"ZeroWork.FilePromise" code:2 userInfo:@{NSLocalizedDescriptionKey:@"下载未完成或已取消"}]); return 0;
    }
    // Take ownership synchronously before Zig removes its completed staging
    // directory. Only the genuine, verified downloaded file is moved here.
    NSURL *source=[NSURL fileURLWithFileSystemRepresentation:staged_path isDirectory:NO relativeToURL:nil];
    NSURL *holding=[[NSURL fileURLWithPath:NSTemporaryDirectory() isDirectory:YES] URLByAppendingPathComponent:[@"zerowork-promise-" stringByAppendingString:NSUUID.UUID.UUIDString] isDirectory:YES];
    NSError *takeError=nil;
    [NSFileManager.defaultManager createDirectoryAtURL:holding withIntermediateDirectories:NO attributes:@{NSFilePosixPermissions:@0700} error:&takeError];
    NSURL *owned=[holding URLByAppendingPathComponent:file.name];
    if (!takeError) [NSFileManager.defaultManager moveItemAtURL:source toURL:owned error:&takeError];
    if (takeError) { [NSFileManager.defaultManager removeItemAtURL:holding error:nil]; completion(takeError); return 0; }
    NSURL *destination=file.destination;
    // File coordination may wait for Finder's reader and must never block the
    // application's UI owner thread. No Zig state is accessed by this block.
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        __block NSError *writeError=nil;
        NSError *coordinationError=nil;
        NSFileCoordinator *coordinator=[[NSFileCoordinator alloc] initWithFilePresenter:nil];
        [coordinator coordinateWritingItemAtURL:destination options:0 error:&coordinationError byAccessor:^(NSURL *url) {
            [NSFileManager.defaultManager moveItemAtURL:owned toURL:url error:&writeError];
        }];
        NSError *error=coordinationError ?: writeError;
        [NSFileManager.defaultManager removeItemAtURL:holding error:nil];
        dispatch_async(dispatch_get_main_queue(), ^{ completion(error); });
    });
    return 1;
}
void zw_file_promises_release(uint64_t token) {
    if (!NSThread.isMainThread) return;
    ZWPromiseSession *session=sessions[@(token)];
    for (ZWPromisedFile *file in session.files) { file.invalidated=YES; if (file.completion && !file.delivered) { file.completion([NSError errorWithDomain:@"ZeroWork.FilePromise" code:3 userInfo:@{NSLocalizedDescriptionKey:@"原会话已关闭"}]); file.completion=nil; file.delivered=YES; } }
    [sessions removeObjectForKey:@(token)];
}
