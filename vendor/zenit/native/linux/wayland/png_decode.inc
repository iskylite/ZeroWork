/* libpng simplified API, loaded only for image clipboard operations. */
typedef struct {
    void *opaque;
    uint32_t version, width, height, format, flags, colormap_entries, warning_or_error;
    char message[64];
} ClipboardPngImage;
int zenit_wayland_decode_png(const unsigned char *bytes, size_t length, ZenitClipboardPng *out) {
    if (!out) return -1;
    memset(out, 0, sizeof(*out));
    if (!bytes || !length || length > 16u * 1024u * 1024u) return -1;
    void *library = dlopen("libpng16.so.16", RTLD_NOW | RTLD_LOCAL);
    if (!library) return -3;
    int (*begin)(ClipboardPngImage *, const void *, size_t) = dlsym(library, "png_image_begin_read_from_memory");
    int (*finish)(ClipboardPngImage *, const void *, void *, int32_t, void *) = dlsym(library, "png_image_finish_read");
    void (*release)(ClipboardPngImage *) = dlsym(library, "png_image_free");
    if (!begin || !finish || !release) { dlclose(library); return -3; }
    ClipboardPngImage image = {.version = 1};
    int result = -1;
    unsigned char *rgba = NULL;
    if (!begin(&image, bytes, length) || !image.width || !image.height || image.width > 4096 || image.height > 4096) goto done;
    image.format = 3; /* PNG_FORMAT_RGBA, straight alpha. */
    size_t size = (size_t)image.width * image.height * 4;
    rgba = malloc(size);
    if (!rgba) { result = -4; goto done; }
    if (!finish(&image, NULL, rgba, (int32_t)(image.width * 4), NULL)) goto done;
    for (size_t i = 0; i < size; i += 4) for (size_t channel = 0; channel < 3; ++channel)
        rgba[i + channel] = (unsigned char)(((unsigned)rgba[i + channel] * rgba[i + 3] + 127) / 255);
    *out = (ZenitClipboardPng){rgba, image.width, image.height};
    rgba = NULL; result = 0;
done:
    free(rgba); release(&image); dlclose(library); return result;
}
void zenit_wayland_free_png(ZenitClipboardPng *image) { if (image) { free(image->rgba); memset(image, 0, sizeof(*image)); } }
