/* macOS ships libarchive.2 without public SDK headers. This is the small C ABI
 * subset used here, checked against libarchive v3.3.3 public headers:
 * https://github.com/libarchive/libarchive/tree/v3.3.3/libarchive
 * No libarchive implementation is bundled. */
#pragma once
#include <sys/types.h>
#include <stddef.h>
struct archive; struct archive_entry;
typedef ssize_t la_ssize_t;
#define ARCHIVE_OK 0
#define ARCHIVE_EOF 1
#define AE_IFDIR S_IFDIR
#define AE_IFREG S_IFREG
#define AE_IFLNK S_IFLNK
struct archive *archive_read_new(void);
int archive_read_support_format_zip(struct archive *);
int archive_read_support_filter_none(struct archive *);
int archive_read_open_filename(struct archive *, const char *, size_t);
int archive_read_next_header(struct archive *, struct archive_entry **);
la_ssize_t archive_read_data(struct archive *, void *, size_t);
int archive_read_free(struct archive *);
const char *archive_entry_pathname_utf8(struct archive_entry *);
const char *archive_entry_hardlink(struct archive_entry *);
const char *archive_entry_symlink_utf8(struct archive_entry *);
int archive_entry_is_encrypted(struct archive_entry *);
mode_t archive_entry_filetype(struct archive_entry *);
mode_t archive_entry_perm(struct archive_entry *);
