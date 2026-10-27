// Headless real-process regression; no app, user files, or Keychain is opened.
#include <assert.h>
#include <signal.h>
#include <sys/wait.h>
static void test_opened(int fd, const char *name);
static const char *test_default_identity(void);
#define ZW_SCOPE_DEFAULT_CREDENTIAL_IDENTITY test_default_identity()
#define ZW_SCOPE_TEST_OPENED(fd, name) test_opened(fd, name)
#include "data_scope_lock.c"

static const char *test_default_identity(void) {
    const char *identity = getenv("ZW_SCOPE_TEST_IDENTITY");
    assert(identity && identity[0] == '/');
    return identity;
}

static int pause_opened;
static char executable[PATH_MAX];
struct child { pid_t pid; int input, output, status; };

static void send_int(int fd, int value) { assert(write(fd, &value, sizeof(value)) == sizeof(value)); }
static int read_int(int fd) { int value; assert(read(fd, &value, sizeof(value)) == sizeof(value)); return value; }
static void test_opened(int fd, const char *name) {
    (void)fd; (void)name;
    if (!pause_opened) return;
    pause_opened = 0;
    send_int(STDOUT_FILENO, 9);
    char byte;
    assert(read(STDIN_FILENO, &byte, 1) == 1);
}
static struct child spawn_child(const char *mode, const char *scope, int isolated) {
    int input[2], output[2];
    assert(pipe(input) == 0 && pipe(output) == 0);
    for (int i = 0; i < 2; ++i) {
        assert(fcntl(input[i], F_SETFD, FD_CLOEXEC) == 0);
        assert(fcntl(output[i], F_SETFD, FD_CLOEXEC) == 0);
    }
    pid_t pid = fork();
    assert(pid >= 0);
    if (pid == 0) {
        assert(dup2(input[0], STDIN_FILENO) == STDIN_FILENO);
        assert(dup2(output[1], STDOUT_FILENO) == STDOUT_FILENO);
        char *const args[] = { executable, (char *)mode, (char *)scope, isolated ? "1" : "0", NULL };
        execv(executable, args);
        _exit(127);
    }
    close(input[0]); close(output[1]);
    struct child result = { pid, input[1], output[0], read_int(output[0]) };
    return result;
}
static void finish_child(struct child child, int release) {
    if (release) assert(write(child.input, "x", 1) == 1);
    close(child.input); close(child.output);
    int status;
    assert(waitpid(child.pid, &status, 0) == child.pid);
    assert(WIFEXITED(status) && WEXITSTATUS(status) == 0);
}
static void absent(int runtime, const char *scope, int global) {
    char name[128]; struct stat st;
    assert(scope_name(scope, global, name) == 0);
    assert(fstatat(runtime, name, &st, AT_SYMLINK_NOFOLLOW) != 0 && errno == ENOENT);
}
static void sentinel_intact(const char *sentinel) {
    char bytes[32] = {0};
    int fd = open(sentinel, O_RDONLY | O_NOFOLLOW);
    assert(fd >= 0 && read(fd, bytes, sizeof(bytes)) == 14);
    close(fd);
    assert(memcmp(bytes, "outside-secret", 14) == 0);
}
int main(int argc, char **argv) {
    if (argc == 4) {
        void *lock = NULL;
        pause_opened = strcmp(argv[1], "--race") == 0;
        int rc = zw_data_scope_lock_acquire(argv[2], atoi(argv[3]), &lock);
        send_int(STDOUT_FILENO, rc);
        if (rc == 0 && strcmp(argv[1], "--hold") == 0) {
            char byte; assert(read(STDIN_FILENO, &byte, 1) == 1);
        }
        zw_data_scope_lock_release(lock);
        return 0;
    }
    alarm(30);
    assert(realpath(argv[0], executable));
    char scratch[] = "/private/tmp/zerowork-scope-test-XXXXXX";
    assert(mkdtemp(scratch));
    // Children inherit this run-unique default-vault identity. Real apps and
    // parallel test runs keep their own locks, even while this test is active.
    assert(setenv("ZW_SCOPE_TEST_IDENTITY", scratch, 1) == 0);
    char a[PATH_MAX], b[PATH_MAX], alias[PATH_MAX], sentinel[PATH_MAX];
    snprintf(a, sizeof(a), "%s/scope-a", scratch);
    snprintf(b, sizeof(b), "%s/scope-b", scratch);
    snprintf(alias, sizeof(alias), "%s/SCOPE-A", scratch);
    snprintf(sentinel, sizeof(sentinel), "%s/sentinel", scratch);
    int runtime = scope_runtime_dir(); assert(runtime >= 0);

    struct child owner = spawn_child("--hold", a, 1); assert(owner.status == ZW_SCOPE_OK);
    struct child duplicate = spawn_child("--try", a, 1); assert(duplicate.status == ZW_SCOPE_BUSY); finish_child(duplicate, 0);
    struct child spelling = spawn_child("--try", alias, 1); assert(spelling.status == ZW_SCOPE_BUSY); finish_child(spelling, 0);
    struct child independent = spawn_child("--hold", b, 1); assert(independent.status == ZW_SCOPE_OK);
    finish_child(owner, 1); finish_child(independent, 1);
    absent(runtime, a, 0); absent(runtime, b, 0);
    puts("PASS: real processes exclude same scope, fold APFS aliases, and allow independent scopes; normal release leaves no runtime files");

    owner = spawn_child("--hold", a, 0); assert(owner.status == ZW_SCOPE_OK);
    duplicate = spawn_child("--try", b, 0); assert(duplicate.status == ZW_SCOPE_BUSY); finish_child(duplicate, 0);
    duplicate = spawn_child("--try", a, 1); assert(duplicate.status == ZW_SCOPE_BUSY); finish_child(duplicate, 0);
    independent = spawn_child("--hold", b, 1); assert(independent.status == ZW_SCOPE_OK);
    finish_child(owner, 1); finish_child(independent, 1);
    absent(runtime, a, 1); absent(runtime, a, 0); absent(runtime, b, 0);
    puts("PASS: shared default vault and default/override directory overlap are serialized; separate override remains concurrent");

    owner = spawn_child("--hold", a, 1); assert(owner.status == 0);
    assert(kill(owner.pid, SIGKILL) == 0);
    int status; assert(waitpid(owner.pid, &status, 0) == owner.pid && WIFSIGNALED(status));
    close(owner.input); close(owner.output);
    void *lock = NULL;
    assert(zw_data_scope_lock_acquire(a, 1, &lock) == 0);
    zw_data_scope_lock_release(lock);
    absent(runtime, a, 0);
    puts("PASS: SIGKILL releases the kernel lock; next process reclaims and removes the stale empty file");

    assert(zw_data_scope_lock_acquire(a, 1, &lock) == 0);
    struct child raced = spawn_child("--race", a, 1); assert(raced.status == 9);
    zw_data_scope_lock_release(lock);
    assert(zw_data_scope_lock_acquire(a, 1, &lock) == 0);
    assert(write(raced.input, "x", 1) == 1);
    assert(read_int(raced.output) == ZW_SCOPE_BUSY);
    finish_child(raced, 0);
    zw_data_scope_lock_release(lock);
    absent(runtime, a, 0);
    puts("PASS: opened-before-unlink race cannot acquire an orphan inode alongside a live new owner");

    int fd = open(sentinel, O_WRONLY | O_CREAT | O_EXCL, 0600);
    assert(fd >= 0 && write(fd, "outside-secret", 14) == 14); close(fd);
    char name[128]; assert(scope_name(a, 0, name) == 0);
    assert(symlinkat(sentinel, runtime, name) == 0);
    assert(zw_data_scope_lock_acquire(a, 1, &lock) == ZW_SCOPE_UNSAFE && lock == NULL);
    sentinel_intact(sentinel); assert(unlinkat(runtime, name, 0) == 0);
    assert(linkat(AT_FDCWD, sentinel, runtime, name, 0) == 0);
    assert(zw_data_scope_lock_acquire(a, 1, &lock) == ZW_SCOPE_UNSAFE && lock == NULL);
    sentinel_intact(sentinel); assert(unlinkat(runtime, name, 0) == 0);
    assert(mkfifoat(runtime, name, 0600) == 0);
    assert(zw_data_scope_lock_acquire(a, 1, &lock) == ZW_SCOPE_UNSAFE && lock == NULL);
    assert(unlinkat(runtime, name, 0) == 0);
    fd = openat(runtime, name, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0600);
    assert(fd >= 0 && write(fd, "outside-secret", 14) == 14); close(fd);
    assert(zw_data_scope_lock_acquire(a, 1, &lock) == ZW_SCOPE_UNSAFE && lock == NULL);
    struct stat retained; assert(fstatat(runtime, name, &retained, AT_SYMLINK_NOFOLLOW) == 0 && retained.st_size == 14);
    assert(unlinkat(runtime, name, 0) == 0);
    assert(zw_data_scope_lock_acquire(a, 1, &lock) == 0);
    // A replacement pathname must never be deleted by the old owner's release.
    assert(unlinkat(runtime, name, 0) == 0);
    assert(symlinkat(sentinel, runtime, name) == 0);
    zw_data_scope_lock_release(lock);
    struct stat st; assert(fstatat(runtime, name, &st, AT_SYMLINK_NOFOLLOW) == 0 && S_ISLNK(st.st_mode));
    sentinel_intact(sentinel); assert(unlinkat(runtime, name, 0) == 0);
    puts("PASS: symlink/hardlink/nonempty sentinel is preserved, FIFO is rejected without blocking, and release never removes a replaced pathname");

    close(runtime);
    assert(unlink(sentinel) == 0 && rmdir(scratch) == 0);
    return 0;
}
