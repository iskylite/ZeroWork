// DXBC disk cache shared by the D3D12 and D3D11 backends (one copy per
// translation unit: each backend keeps its own in-flight table).
#pragma once
#include <windows.h>
#include <d3dcompiler.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>

// ── DXBC disk cache ───────────────────────────────────────────────────────
// D3DCompile of the runtime HLSL is the one-time cost behind "the first glass
// story takes two seconds" (glass.hlsl alone ~1.9 s on a GTX 1650 box). The
// bytecode only depends on the source text, entry, profile and compile flags,
// so it is kept under %LOCALAPPDATA%\zenit\shader-cache keyed by a hash of
// exactly those plus a per-backend format tag; bumping the tag drops every old
// entry, and the flags and compiler header version are hashed as well.
// ZENIT_SHADER_CACHE_DIR overrides the directory; ZENIT_SHADER_CACHE=0 disables.
// A corrupt or truncated entry is ignored and recompiled; writes go through a
// private temp file and MoveFileEx, so readers never see a partial blob.
// Entry layout: 16-byte header {magic "ZDXC", payload size, FNV-1a 64 of the
// payload} then the DXBC. A header mismatch (truncated by a crash before the
// data reached disk, partial overwrite, foreign file) means recompile; a
// blob that passed D3DCompile is never served from a corrupt file, which
// would otherwise fail PSO creation and trip the sticky "glass pipeline
// failed" flag for the whole session.
struct CacheHeader { char magic[4]; uint32_t size; uint64_t checksum; };
static uint64_t fnv64(const void *data, size_t size) {
    uint64_t h = 1469598103934665603ULL;
    const unsigned char *p = (const unsigned char *)data;
    for (size_t i = 0; i < size; ++i) h = (h ^ p[i]) * 1099511628211ULL;
    return h;
}
static void cache_hash(const char *tag, UINT compile_flags, const void *source, size_t source_size, const char *entry, const char *profile, char out[33]) {
    // Two independent FNV-1a 64 lanes over the same stream: 128 bits is far
    // beyond collision concern for a per-user cache of a few dozen shaders.
    uint64_t a = 1469598103934665603ULL, b = 0x9E3779B97F4A7C15ULL;
    auto feed = [&](const void *data, size_t size) {
        const unsigned char *p = (const unsigned char *)data;
        for (size_t i = 0; i < size; ++i) {
            a = (a ^ p[i]) * 1099511628211ULL;
            b = (b ^ (p[i] + 0x9E)) * 0x100000001B3ULL;
        }
        a = (a ^ 0x1F) * 1099511628211ULL; b = (b ^ 0x2E) * 0x100000001B3ULL; // field separator
    };
    const uint32_t flags = compile_flags, compiler = D3D_COMPILER_VERSION;
    feed(tag, strlen(tag)); feed(&flags, sizeof flags); feed(&compiler, sizeof compiler);
    feed(source, source_size); feed(entry, strlen(entry)); feed(profile, strlen(profile));
    snprintf(out, 33, "%016llx%016llx", (unsigned long long)a, (unsigned long long)b);
}
static bool cache_path(const char hash[33], wchar_t out[MAX_PATH]) {
    wchar_t dir[MAX_PATH];
    DWORD n = GetEnvironmentVariableW(L"ZENIT_SHADER_CACHE", dir, MAX_PATH);
    if (n == 1 && dir[0] == L'0') return false;
    n = GetEnvironmentVariableW(L"ZENIT_SHADER_CACHE_DIR", dir, MAX_PATH);
    if (n == 0 || n >= MAX_PATH) {
        n = GetEnvironmentVariableW(L"LOCALAPPDATA", dir, MAX_PATH);
        if (n == 0 || n >= MAX_PATH - 20) return false;
        wcscat(dir, L"\\zenit");
        CreateDirectoryW(dir, nullptr);
        wcscat(dir, L"\\shader-cache");
    }
    CreateDirectoryW(dir, nullptr);
    wchar_t name[48];
    for (int i = 0; i < 32; ++i) name[i] = (wchar_t)hash[i];
    name[32] = 0;
    if (wcslen(dir) + 40 >= MAX_PATH) return false;
    swprintf(out, MAX_PATH, L"%s\\%s.dxbc", dir, name);
    return true;
}
static ID3DBlob *cache_load(const wchar_t *path) {
    HANDLE file = CreateFileW(path, GENERIC_READ, FILE_SHARE_READ | FILE_SHARE_DELETE, nullptr, OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL, nullptr);
    if (file == INVALID_HANDLE_VALUE) return nullptr;
    LARGE_INTEGER size = {};
    ID3DBlob *blob = nullptr;
    CacheHeader header = {};
    DWORD read = 0;
    bool ok = GetFileSizeEx(file, &size) && size.QuadPart > (LONGLONG)sizeof header && size.QuadPart < (64 << 20) &&
        ReadFile(file, &header, sizeof header, &read, nullptr) && read == sizeof header &&
        memcmp(header.magic, "ZDXC", 4) == 0 && header.size == (uint64_t)size.QuadPart - sizeof header && header.size > 4;
    if (ok && SUCCEEDED(D3DCreateBlob(header.size, &blob))) {
        const char *bytes = (const char *)blob->GetBufferPointer();
        if (!ReadFile(file, blob->GetBufferPointer(), header.size, &read, nullptr) || read != header.size ||
            memcmp(bytes, "DXBC", 4) != 0 || fnv64(bytes, header.size) != header.checksum) {
            blob->Release(); blob = nullptr;
        }
    }
    CloseHandle(file);
    if (!blob) DeleteFileW(path); // a bad entry is never retried: recompile and rewrite
    return blob;
}
static void cache_store(const wchar_t *path, ID3DBlob *code) {
    wchar_t tmp[MAX_PATH + 32];
    swprintf(tmp, MAX_PATH + 32, L"%s.%lu.%lu.tmp", path, (unsigned long)GetCurrentProcessId(), (unsigned long)GetCurrentThreadId());
    HANDLE file = CreateFileW(tmp, GENERIC_WRITE, 0, nullptr, CREATE_ALWAYS, FILE_ATTRIBUTE_NORMAL, nullptr);
    if (file == INVALID_HANDLE_VALUE) return;
    CacheHeader header = {{'Z', 'D', 'X', 'C'}, (uint32_t)code->GetBufferSize(), fnv64(code->GetBufferPointer(), code->GetBufferSize())};
    DWORD written = 0;
    bool ok = WriteFile(file, &header, sizeof header, &written, nullptr) && written == sizeof header &&
        WriteFile(file, code->GetBufferPointer(), (DWORD)code->GetBufferSize(), &written, nullptr) && written == code->GetBufferSize() &&
        FlushFileBuffers(file); // data reaches disk before the rename makes it visible
    CloseHandle(file);
    if (!ok || !MoveFileExW(tmp, path, MOVEFILE_REPLACE_EXISTING)) DeleteFileW(tmp);
}
// In-flight compiles by cache key: the startup warm-up thread and a first
// glass frame asking for the same shader must not both run the 2 s compile.
// The second caller waits for the first and then takes the cache hit.
static SRWLOCK inflight_lock = SRWLOCK_INIT;
static CONDITION_VARIABLE inflight_done = CONDITION_VARIABLE_INIT;
static char inflight[16][33];
static int inflight_find(const char hash[33]) {
    for (int i = 0; i < 16; ++i) if (memcmp(inflight[i], hash, 32) == 0) return i;
    return -1;
}
// Returns true when this caller owns the compile; false when the entry was
// produced by another thread meanwhile (reload from the cache). Capacity
// exhaustion just compiles redundantly.
static bool inflight_claim(const char hash[33]) {
    AcquireSRWLockExclusive(&inflight_lock);
    bool waited = false;
    while (inflight_find(hash) >= 0) { SleepConditionVariableSRW(&inflight_done, &inflight_lock, INFINITE, 0); waited = true; }
    if (!waited) {
        for (int i = 0; i < 16; ++i) if (inflight[i][0] == 0) { memcpy(inflight[i], hash, 33); break; }
    }
    ReleaseSRWLockExclusive(&inflight_lock);
    return !waited;
}
static void inflight_release(const char hash[33]) {
    AcquireSRWLockExclusive(&inflight_lock);
    int i = inflight_find(hash);
    if (i >= 0) inflight[i][0] = 0;
    ReleaseSRWLockExclusive(&inflight_lock);
    WakeAllConditionVariable(&inflight_done);
}

// D3DCompile through the cache. `tag` names the backend's bytecode format;
// `source_name` only labels diagnostics. Includes are disabled: never read
// files relative to the process cwd. On return *code holds the bytecode (or
// null on failure) and *messages the compiler output when it ran.
static HRESULT dxbc_compile_cached(const char *tag, const void *source, size_t source_size, const char *source_name,
    const char *entry, const char *profile, UINT flags, ID3DBlob **code, ID3DBlob **messages) {
    *code = nullptr; *messages = nullptr;
    char hash[33]; wchar_t path[MAX_PATH];
    cache_hash(tag, flags, source, source_size, entry, profile, hash);
    const bool cacheable = cache_path(hash, path);
    if (cacheable) *code = cache_load(path);
    HRESULT hr = S_OK;
    bool compiled = false;
    while (!*code && !compiled) {
        if (cacheable && !inflight_claim(hash)) {
            // Another thread finished this entry; take it, or become the next
            // owner when its compile or store failed (no concurrent recompile).
            *code = cache_load(path);
            continue;
        }
        hr = D3DCompile(source, source_size, source_name, nullptr, nullptr, entry, profile, flags, 0, code, messages);
        compiled = true;
        if (cacheable) {
            if (SUCCEEDED(hr) && *code) cache_store(path, *code);
            inflight_release(hash);
        }
    }
    return hr;
}
