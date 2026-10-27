// One live process owns a data directory (and the shared default credential
// vault). Runtime locks contain no application data and never touch Keychain.
#include <CoreFoundation/CoreFoundation.h>
#include <CommonCrypto/CommonDigest.h>
#include <errno.h>
#include <fcntl.h>
#include <limits.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/file.h>
#include <sys/stat.h>
#include <unistd.h>

#ifndef ZW_SCOPE_TEST_OPENED
#define ZW_SCOPE_TEST_OPENED(fd, name) ((void)0)
#endif

// Tests override this identity at compile time; production always uses the
// fixed credential service identity, independent of runtime environment.
#ifndef ZW_SCOPE_DEFAULT_CREDENTIAL_IDENTITY
#define ZW_SCOPE_DEFAULT_CREDENTIAL_IDENTITY "com.zerowork.app.default-credential-vault"
#endif

enum { ZW_SCOPE_OK = 0, ZW_SCOPE_BUSY = 1, ZW_SCOPE_UNSAFE = 2, ZW_SCOPE_FAILURE = 3 };
struct scope_file { int fd; char name[128]; };
struct scope_lock { int parent; size_t count; struct scope_file files[2]; };

static int scope_runtime_dir(void) {
    int base = open("/private", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC);
    if (base < 0) return -1;
    struct stat st;
    if (fstat(base, &st) != 0 || !S_ISDIR(st.st_mode) || st.st_uid != 0 || (st.st_mode & 0022)) {
        close(base); errno = EPERM; return -1;
    }
    int dir = openat(base, "tmp", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC);
    close(base);
    if (dir < 0) return -1;
    if (fstat(dir, &st) != 0 || !S_ISDIR(st.st_mode) || st.st_uid != 0 || !(st.st_mode & S_ISVTX)) {
        close(dir); errno = EPERM; return -1;
    }
    return dir;
}

static int scope_name(const char *directory, int global_default, char out[128]) {
    unsigned char digest[CC_SHA256_DIGEST_LENGTH];
    if (global_default) {
        const char *identity = ZW_SCOPE_DEFAULT_CREDENTIAL_IDENTITY;
        CC_SHA256(identity, (CC_LONG)strlen(identity), digest);
    } else {
        // Paths rejects traversal and lifecycle rejects all symlink components.
        // Folding also serializes spelling aliases on case-insensitive APFS.
        CFStringRef source = CFStringCreateWithCString(kCFAllocatorDefault, directory, kCFStringEncodingUTF8);
        if (!source) return ZW_SCOPE_UNSAFE;
        CFMutableStringRef folded = CFStringCreateMutableCopy(kCFAllocatorDefault, 0, source);
        CFRelease(source);
        if (!folded) return ZW_SCOPE_FAILURE;
        CFStringNormalize(folded, kCFStringNormalizationFormD);
        CFStringFold(folded, kCFCompareCaseInsensitive, NULL);
        CFIndex capacity = CFStringGetMaximumSizeForEncoding(CFStringGetLength(folded), kCFStringEncodingUTF8) + 1;
        if (capacity <= 0 || capacity > 4 * PATH_MAX) { CFRelease(folded); return ZW_SCOPE_UNSAFE; }
        char *bytes = malloc((size_t)capacity);
        if (!bytes) { CFRelease(folded); return ZW_SCOPE_FAILURE; }
        if (!CFStringGetCString(folded, bytes, capacity, kCFStringEncodingUTF8)) {
            free(bytes); CFRelease(folded); return ZW_SCOPE_UNSAFE;
        }
        CC_SHA256(bytes, (CC_LONG)strlen(bytes), digest);
        free(bytes);
        CFRelease(folded);
    }
    char hex[2 * CC_SHA256_DIGEST_LENGTH + 1];
    for (size_t i = 0; i < sizeof(digest); ++i) snprintf(hex + 2 * i, 3, "%02x", digest[i]);
    snprintf(out, 128, ".zerowork-scope-%u-%s.lock", (unsigned)geteuid(), hex);
    return ZW_SCOPE_OK;
}

static int scope_safe_file(const struct stat *st) {
    return S_ISREG(st->st_mode) && st->st_uid == geteuid() && st->st_nlink == 1 &&
           (st->st_mode & 07777) == 0600 && st->st_size == 0;
}
static int scope_same_file(const struct stat *a, const struct stat *b) {
    return a->st_dev == b->st_dev && a->st_ino == b->st_ino;
}

static int scope_acquire_file(int parent, struct scope_file *file) {
    for (int attempt = 0; attempt < 16; ++attempt) {
        int created = 1;
        int fd = openat(parent, file->name, O_RDWR | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK, 0600);
        if (fd < 0 && errno == EEXIST) {
            created = 0;
            fd = openat(parent, file->name, O_RDWR | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK);
        }
        if (fd < 0) {
            if (errno == ENOENT) continue; // another owner just completed release
            return errno == ELOOP ? ZW_SCOPE_UNSAFE : ZW_SCOPE_FAILURE;
        }
        if (created && fchmod(fd, 0600) != 0) { close(fd); return ZW_SCOPE_FAILURE; }
        struct stat held, named;
        if (fstat(fd, &held) != 0) { close(fd); return ZW_SCOPE_FAILURE; }
        if (held.st_nlink == 0) { close(fd); continue; }
        if (!scope_safe_file(&held)) { close(fd); return ZW_SCOPE_UNSAFE; }
        ZW_SCOPE_TEST_OPENED(fd, file->name);
        int rc;
        do { rc = flock(fd, LOCK_EX | LOCK_NB); } while (rc != 0 && errno == EINTR);
        if (rc != 0) {
            int busy = errno == EWOULDBLOCK || errno == EAGAIN;
            close(fd);
            return busy ? ZW_SCOPE_BUSY : ZW_SCOPE_FAILURE;
        }
        // A process may have opened the old inode immediately before release
        // unlinked it. It must retry the current pathname after gaining flock.
        if (fstat(fd, &held) != 0) { close(fd); return ZW_SCOPE_FAILURE; }
        if (fstatat(parent, file->name, &named, AT_SYMLINK_NOFOLLOW) != 0) {
            int missing = errno == ENOENT;
            close(fd);
            if (missing) continue;
            return ZW_SCOPE_FAILURE;
        }
        if (!scope_safe_file(&named)) { close(fd); return ZW_SCOPE_UNSAFE; }
        if (!scope_same_file(&held, &named)) { close(fd); continue; }
        file->fd = fd;
        return ZW_SCOPE_OK;
    }
    return ZW_SCOPE_FAILURE;
}

void zw_data_scope_lock_release(void *opaque) {
    struct scope_lock *lock = opaque;
    if (!lock) return;
    while (lock->count) {
        struct scope_file *file = &lock->files[--lock->count];
        struct stat held, named;
        if (fstat(file->fd, &held) == 0 && fstatat(lock->parent, file->name, &named, AT_SYMLINK_NOFOLLOW) == 0 &&
            scope_safe_file(&named) && scope_same_file(&held, &named)) {
            // Still holding flock. A new owner validates its inode after
            // acquisition, so unlink/close cannot create two live owners.
            (void)unlinkat(lock->parent, file->name, 0);
        }
        close(file->fd);
    }
    close(lock->parent);
    free(lock);
}

int zw_data_scope_lock_acquire(const char *directory, int isolated, void **out) {
    if (!out) return ZW_SCOPE_UNSAFE;
    *out = NULL;
    if (!directory || directory[0] != '/' || strlen(directory) > PATH_MAX) return ZW_SCOPE_UNSAFE;
    struct scope_lock *lock = calloc(1, sizeof(*lock));
    if (!lock) return ZW_SCOPE_FAILURE;
    lock->parent = scope_runtime_dir();
    if (lock->parent < 0) { free(lock); return ZW_SCOPE_UNSAFE; }
    // Default credentials share one service regardless of HOME. Also take the
    // directory lock, so an explicit instance cannot open the default files.
    for (int global = !isolated; global >= 0; --global) {
        struct scope_file *file = &lock->files[lock->count];
        int rc = scope_name(directory, global, file->name);
        if (rc == ZW_SCOPE_OK) rc = scope_acquire_file(lock->parent, file);
        if (rc != ZW_SCOPE_OK) { zw_data_scope_lock_release(lock); return rc; }
        ++lock->count;
    }
    *out = lock;
    return ZW_SCOPE_OK;
}
