// presentDrawable: schedules presentation on Metal's worker. The caller's
// autorelease pool cannot cover that execution. CA's present implementation
// creates autoreleased callback containers which retain the backing layer.
// Preserve scheduled presentation, but bound those temporaries on its thread.
static void zenitScheduleDrawablePresentation(id<MTLCommandBuffer> buffer, id<CAMetalDrawable> drawable) {
    __block id<CAMetalDrawable> pendingDrawable=drawable;
    [buffer addScheduledHandler:^(id<MTLCommandBuffer> scheduled) {
        @autoreleasepool {
            [pendingDrawable present];
            // Metal disposes its scheduled-handler block outside this pool.
            // Release the captured drawable here too: its destruction can
            // autorelease the backing layer and CA callback containers.
            pendingDrawable=nil;
        }
    }];
}
