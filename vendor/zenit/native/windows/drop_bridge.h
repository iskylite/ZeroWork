#pragma once
#include <stddef.h>
#include <stdint.h>
typedef struct ZenitDragPacket {
    float x,y;
    uint32_t kind,payload_kind,truncated,operation;
    const char *bytes;
    size_t length;
    uint64_t serial;
    uint64_t source_token;
} ZenitDragPacket;
#if defined(__cplusplus) && defined(_WIN64)
static_assert(sizeof(ZenitDragPacket)==56 && offsetof(ZenitDragPacket,bytes)==24 && offsetof(ZenitDragPacket,serial)==40 && offsetof(ZenitDragPacket,source_token)==48,"Zig drag packet ABI");
#endif
#ifdef __cplusplus
extern "C" {
#endif
void *zenit_drop_create(void *hwnd, uint64_t (*next_serial)(void *), void *context);
void zenit_drop_destroy(void *target);
int zenit_drop_set_operations(void *target, unsigned operations);
int zenit_drop_peek(void *target, ZenitDragPacket *packet);
int zenit_drop_consume(void *target, uint64_t serial);
#ifdef __cplusplus
}
#endif
