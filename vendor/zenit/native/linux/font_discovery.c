/* Private Fontconfig configuration per discovery operation. Returned file
 * names are copied before patterns/configuration are destroyed. */
#include <fontconfig/fontconfig.h>
#include <stddef.h>
#include <string.h>

int zenit_linux_find_font(const char *family, int weight, int italic,
                         char *path, size_t capacity, int *index) {
    if (!family || !path || !capacity || !index || weight < 1 || weight > 1000)
        return 0;
    path[0] = '\0';
    *index = 0;
    int success = 0;
    FcConfig *config = FcConfigCreate();
    FcPattern *request = NULL, *match = NULL;
    if (!config || !FcConfigParseAndLoad(config, NULL, FcTrue) ||
        !FcConfigBuildFonts(config)) goto done;
    request = FcPatternCreate();
    if (!request ||
        !FcPatternAddString(request, FC_FAMILY, (const FcChar8 *)family) ||
        !FcPatternAddInteger(request, FC_WEIGHT, FcWeightFromOpenType(weight)) ||
        !FcPatternAddInteger(request, FC_SLANT, italic ? FC_SLANT_ITALIC : FC_SLANT_ROMAN) ||
        !FcPatternAddBool(request, FC_SCALABLE, FcTrue) ||
        !FcConfigSubstitute(config, request, FcMatchPattern)) goto done;
    FcDefaultSubstitute(request);
    FcResult result;
    match = FcFontMatch(config, request, &result);
    FcChar8 *file = NULL;
    int face_index = 0;
    if (!match || FcPatternGetString(match, FC_FILE, 0, &file) != FcResultMatch || !file)
        goto done;
    if (FcPatternGetInteger(match, FC_INDEX, 0, &face_index) != FcResultMatch)
        face_index = 0;
    if (face_index < 0) goto done;
    const size_t length = strlen((const char *)file);
    if (length >= capacity) goto done;
    memcpy(path, file, length + 1);
    *index = face_index;
    success = 1;
done:
    if (match) FcPatternDestroy(match);
    if (request) FcPatternDestroy(request);
    if (config) FcConfigDestroy(config);
    return success;
}
