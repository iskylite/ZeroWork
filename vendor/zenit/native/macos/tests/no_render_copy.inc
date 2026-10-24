// Window/input-only tests must never submit a GPU texture copy.
// Fullscreen snapshot tests provide their own checked copy fixture.
#ifndef ZENIT_TEST_RENDER_COPY_FIXTURE
#include <stdio.h>
#include <stdlib.h>
int metal_command_buffer_copy_texture_region_render(void *buffer, void *source,
    unsigned x, unsigned y, unsigned width, unsigned height, void *destination,
    unsigned dx, unsigned dy, int flip) {
    fprintf(stderr, "Unexpected GPU texture copy in a window/input-only test\n");
    abort();
}
#endif
