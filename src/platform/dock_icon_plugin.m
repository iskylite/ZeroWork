#import "dock_icon_preferences.h"

@interface ZWDockIconPlugin : NSObject <NSDockTilePlugIn>
@property(nonatomic, strong) NSDockTile *tile;
@property(nonatomic, strong) id observer;
@property(nonatomic, copy) NSString *domain;
@end

@implementation ZWDockIconPlugin
- (void)dealloc {
    if (_observer) [NSDistributedNotificationCenter.defaultCenter removeObserver:_observer];
}
- (void)setDockTile:(NSDockTile *)tile {
    // Dock can retain this object after the application quits. Subscribe only
    // while its tile exists, and keep all AppKit work on the main thread.
    if (!NSThread.isMainThread) {
        __weak ZWDockIconPlugin *weakSelf = self;
        dispatch_async(dispatch_get_main_queue(), ^{ [weakSelf setDockTile:tile]; });
        return;
    }
    if (self.observer) {
        [NSDistributedNotificationCenter.defaultCenter removeObserver:self.observer];
        self.observer = nil;
    }
    self.tile = tile;
    if (!tile) return;
    self.domain = [[NSBundle bundleForClass:self.class] objectForInfoDictionaryKey:@"ZeroWorkApplicationIdentifier"];
    if (!self.domain.length) return;
    __weak ZWDockIconPlugin *weakSelf = self;
    self.observer = [NSDistributedNotificationCenter.defaultCenter addObserverForName:ZWDockIconNotification object:self.domain queue:NSOperationQueue.mainQueue usingBlock:^(NSNotification *notification) {
        [weakSelf refreshIcon];
    }];
    [self refreshIcon];
}
- (void)refreshIcon {
    if (!self.tile) return;
    NSBundle *bundle = [NSBundle bundleForClass:self.class];
    NSString *path = [bundle pathForResource:ZWDockIconResource(ZWDockIconReadStyle(self.domain)) ofType:@"png"];
    NSImage *image = [[NSImage alloc] initWithContentsOfFile:path];
    if (!image.valid) return;
    NSImageView *view = [[NSImageView alloc] initWithFrame:(NSRect){NSZeroPoint, self.tile.size}];
    view.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    view.imageScaling = NSImageScaleProportionallyUpOrDown;
    view.image = image;
    self.tile.contentView = view;
    [self.tile display];
}
@end
