#pragma once
#include <stdint.h>
#ifdef __cplusplus
extern "C" {
#endif
typedef struct ZenitRecordingState {
    int32_t ok, active;
    uint32_t width, height, fps, reserved;
    uint64_t duration_ms, file_size, frame_count, dropped_frames;
    char path[768], error_message[256];
} ZenitRecordingState;
typedef struct ZenitRecordingFrame {
    const uint8_t *bytes;
    uint32_t width, height, stride;
} ZenitRecordingFrame;
void *zenit_recording_start(const char *, uint32_t, uint32_t, uint32_t, ZenitRecordingState *);
void zenit_recording_status(void *, ZenitRecordingState *);
int zenit_recording_due(void *);
int zenit_recording_append(void *, const ZenitRecordingFrame *);
void zenit_recording_stop(void *, ZenitRecordingState *);
void zenit_recording_destroy(void *);
#ifdef __cplusplus
}
#endif
