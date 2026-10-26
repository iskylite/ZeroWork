#pragma once
#include <stdint.h>
#include <stddef.h>
uint64_t zw_file_promises_begin(uint32_t window_id, const char *const *names, size_t count, float x, float y);
int zw_file_promises_poll(uint64_t token, uint32_t *index, char *destination, size_t capacity);
int zw_file_promises_status(uint64_t token);
// Takes ownership of a real completed staging file; returns acceptance, not
// Finder delivery success. Finder receives its asynchronous completion/error.
int zw_file_promises_complete(uint64_t token, uint32_t index, const char *staged_path);
void zw_file_promises_release(uint64_t token);
