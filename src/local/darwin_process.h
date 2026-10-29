#ifndef ZEROWORK_LOCAL_DARWIN_PROCESS_H
#define ZEROWORK_LOCAL_DARWIN_PROCESS_H
#include <stddef.h>
#include <stdint.h>

typedef struct zw_local_process ZW_LOCAL_PROCESS;
typedef struct { int stage; int error_number; } ZW_LOCAL_FAILURE;
typedef struct { int kind; int value; } ZW_LOCAL_EXIT;
typedef struct { int pid; int process_group; int session_id; char name[64]; } ZW_LOCAL_FOREGROUND;
/* Observation stages: 1 list size, 2 list data, 3 allocation, 4 member
 * metadata, 5 session trust, 6 wait observation, 7 wait reap, 8 group trust,
 * 9 signal delivery. errno belongs to that observation, not a later syscall. */
typedef struct { int stage; int error_number; int pid; } ZW_LOCAL_OBSERVATION_FAILURE;

/* Stage: 1 cwd, 2 PTY, 3 pipes, 4 spawn, 5 ownership. Fixed backend only. */
ZW_LOCAL_PROCESS *zw_local_start_pty(const char *cwd, const char *term,
    unsigned short cols, unsigned short rows, ZW_LOCAL_FAILURE *failure);
ZW_LOCAL_PROCESS *zw_local_start_exec(const char *cwd, const char *command,
    ZW_LOCAL_FAILURE *failure);
/* Read: 1 bytes, 0 would-block, 2 EOF, -1 error. Empty buffers do not imply EOF. */
int zw_local_read(ZW_LOCAL_PROCESS *, int stream, unsigned char *, size_t, size_t *);
int zw_local_write(ZW_LOCAL_PROCESS *, const unsigned char *, size_t, size_t *);
int zw_local_resize(ZW_LOCAL_PROCESS *, unsigned short cols, unsigned short rows);
int zw_local_dimensions(ZW_LOCAL_PROCESS *, unsigned short *cols, unsigned short *rows);
/* Exit: 0 still running, 1 reaped (kind 1 exit / 2 signal), -1 unknown. */
int zw_local_poll_exit(ZW_LOCAL_PROCESS *, ZW_LOCAL_EXIT *);
int zw_local_foreground(ZW_LOCAL_PROCESS *, ZW_LOCAL_FOREGROUND *);
int zw_local_interrupt_foreground(ZW_LOCAL_PROCESS *);
int zw_local_pid(ZW_LOCAL_PROCESS *);
const char *zw_local_initial_cwd(ZW_LOCAL_PROCESS *);
/* Kernel cwd, not parsed from a prompt. 0 means currently unknown. */
int zw_local_cwd(ZW_LOCAL_PROCESS *, char *buffer, size_t capacity);
/* Idempotent. 0 awaiting, 1 released, 2 unknown; HUP / +2s TERM / +2s KILL.
 * A group that exits between the ownership scan and signal verification is
 * re-observed for at most 250ms; no signal uses the invalidated identities.
 * The consumer must continue draining output through EOF before release. */
int zw_local_close_step(ZW_LOCAL_PROCESS *, uint64_t monotonic_ms);
/* Last failed ownership/exit observation; diagnostic evidence, never release. */
int zw_local_observation_failure(ZW_LOCAL_PROCESS *, ZW_LOCAL_OBSERVATION_FAILURE *);
int zw_local_destroy(ZW_LOCAL_PROCESS *);
uint64_t zw_local_monotonic_ms(void);
int zw_local_last_error(void);
#endif
