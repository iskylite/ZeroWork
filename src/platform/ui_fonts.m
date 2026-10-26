#include <CoreText/CoreText.h>
#include <CoreGraphics/CoreGraphics.h>
#include <stdbool.h>
// Registration is local to this process; no system/user font installation.
bool zw_register_ui_font(const unsigned char *bytes, size_t length) {
    CGDataProviderRef provider = CGDataProviderCreateWithData(NULL, bytes, length, NULL);
    if (!provider) return false;
    CGFontRef font = CGFontCreateWithDataProvider(provider);
    CGDataProviderRelease(provider);
    if (!font) return false;
    CFErrorRef error = NULL;
    bool ok = CTFontManagerRegisterGraphicsFont(font, &error);
    if (error) CFRelease(error);
    CGFontRelease(font);
    return ok;
}
