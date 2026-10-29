#include <sys/socket.h>
#include <sys/un.h>
#include <sys/stat.h>
#include <sys/wait.h>
#include <unistd.h>
#include <fcntl.h>
#include <errno.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
struct secret;
extern struct secret *zw_local_secret_create(void *);
extern void zw_local_secret_destroy(struct secret *);
extern int zw_local_secret_read(struct secret *, int, unsigned char *, size_t, size_t *);
extern int zw_local_secret_write(struct secret *, const unsigned char *, size_t, size_t *);
const char *zw_local_edit_directory(void *context) { return context; }
static int connect_to(const char *path) {
    int fd = socket(AF_UNIX, SOCK_STREAM, 0);
    if (fd < 0) return -1;
    struct sockaddr_un address = { .sun_family = AF_UNIX };
    strcpy(address.sun_path, path);
    if (connect(fd, (struct sockaddr *)&address, sizeof(address))) { close(fd); return -1; }
    return fd;
}
static void pause_ms(void) { usleep(1000); }
int main(void) {
    char directory[] = "/tmp/zw-secret-peer-test-XXXXXX";
    if (!mkdtemp(directory) || chmod(directory, 0700)) return 1;
    struct secret *secret = zw_local_secret_create(directory);
    if (!secret) return 2;
    char path[104]; snprintf(path, sizeof(path), "%s/execution-secret", directory);
    struct stat mode;
    if (stat(path, &mode) || (mode.st_mode & 0777) != 0600) return 3;
    pid_t child = fork();
    if (child < 0) return 4;
    if (!child) {
        int fd = connect_to(path);
        if (fd < 0) _exit(5);
        unsigned char value = 0;
        /* Parent must reject this same-UID child's connection before any data
         * can be sent. EOF is a rejection; receiving even one byte is failure. */
        ssize_t count = read(fd, &value, 1);
        close(fd);
        _exit(count == 0 ? 0 : 6);
    }
    unsigned char buffer[64];
    int status = 0, exited = 0;
    for (int i = 0; i < 3000; ++i) {
        size_t count = 0;
        int result = zw_local_secret_read(secret, getpid(), buffer, sizeof(buffer), &count);
        if (result != 0 || count != 0) return 7;
        if (waitpid(child, &status, WNOHANG) == child) { exited = 1; break; }
        pause_ms();
    }
    if (!exited || !WIFEXITED(status) || WEXITSTATUS(status) != 0) return 8;
    /* A new same-process connection made after the earlier fork is accepted. */
    int fd = connect_to(path);
    if (fd < 0) return 9;
    size_t count = 0;
    if (zw_local_secret_read(secret, getpid(), buffer, sizeof(buffer), &count) != 3) return 10;
    const unsigned char payload[] = "native-peer-private-test";
    if (zw_local_secret_write(secret, payload, sizeof(payload), &count) != 1 || count != sizeof(payload)) return 11;
    if (read(fd, buffer, sizeof(buffer)) != sizeof(payload) || memcmp(buffer, payload, sizeof(payload))) return 12;
    close(fd);
    zw_local_secret_destroy(secret);
    if (access(path, F_OK) == 0 || rmdir(directory)) return 13;
    puts("PASS: fresh private secret socket rejects a same-UID forked child, accepts the original PID, enforces 0600, and removes only its own path");
    return 0;
}
