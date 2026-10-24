/* libpng 1.6 simplified API ABI. Resolve at capture time so rendering does not
 * depend on libpng development headers or a linked image codec. */
typedef struct {
    void *opaque;
    uint32_t version, width, height, format, flags, colormap_entries, warning_or_error;
    char message[64];
} ZenitPngImage;

int zenit_linux_write_png_rgba(const char *path, const uint8_t *rgba, size_t length,
                          uint32_t width, uint32_t height, uint32_t stride) {
    if (!path || !*path || !rgba || !width || !height ||
        width > INT_MAX / 4 || stride > INT_MAX || stride < width * 4) return 0;
    const size_t row = (size_t)width * 4;
    if ((size_t)(height - 1) > (SIZE_MAX - row) / stride ||
        (size_t)(height - 1) * stride + row > length) return 0;
    void *library = dlopen("libpng16.so.16", RTLD_NOW | RTLD_LOCAL);
    if (!library) return 0;
    int (*write_image)(ZenitPngImage *, const char *, int, const void *, int32_t, const void *) =
        dlsym(library, "png_image_write_to_file");
    void (*free_image)(ZenitPngImage *) = dlsym(library, "png_image_free");
    if (!write_image || !free_image) { dlclose(library); return 0; }
    ZenitPngImage image = {0};
    image.version = 1;
    image.width = width;
    image.height = height;
    image.format = 3; /* PNG_FORMAT_RGBA: 8-bit color with straight alpha. */
    int result = write_image(&image, path, 0, rgba, (int32_t)stride, NULL);
    free_image(&image);
    dlclose(library);
    return result != 0;
}

/* Preserve the existing native Vulkan bootstrap ABI for probe consumers. */
int zenit_vk_write_png_rgba(const char *path, const uint8_t *rgba, size_t length,
                          uint32_t width, uint32_t height, uint32_t stride) {
    return zenit_linux_write_png_rgba(path, rgba, length, width, height, stride);
}
