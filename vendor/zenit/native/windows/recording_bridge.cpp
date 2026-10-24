// Window content only: completed BGRA drawable -> bounded queue -> MF H.264/MP4.
// COM, transforms and disk I/O stay on the worker. Queue saturation drops a
// frame; it never waits for encoder throughput. API calls are UI-thread owned.
#include "recording_bridge.h"
#include <windows.h>
#include <mfapi.h>
#include <mfidl.h>
#include <mfreadwrite.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <new>

namespace {
constexpr unsigned capacity = 4;
struct Frame { uint8_t *bytes = nullptr; LONGLONG time = 0; };
struct Recorder {
    SRWLOCK lock = SRWLOCK_INIT;
    CONDITION_VARIABLE changed = CONDITION_VARIABLE_INIT;
    HANDLE thread = nullptr;
    bool ready = false, stopping = false;
    ZenitRecordingState state{};
    wchar_t path[768]{};
    uint32_t input_width = 0, input_height = 0;
    Frame frames[capacity];
    unsigned head = 0, count = 0;
    LONGLONG origin = 0, last = -1, first = -1, frequency = 0;
};
void fail(Recorder *r, const char *stage, HRESULT hr) {
    AcquireSRWLockExclusive(&r->lock);
    r->state.ok = r->state.active = 0;
    snprintf(r->state.error_message, sizeof(r->state.error_message), "%s (HRESULT 0x%08lx)", stage, (unsigned long)hr);
    r->stopping = true;
    WakeAllConditionVariable(&r->changed);
    ReleaseSRWLockExclusive(&r->lock);
}
template<class T> void release(T *&p) { if (p) p->Release(); p = nullptr; }
// Optional capability: Windows N / stripped installations without MF must
// still launch and render. Resolve only when the user starts a recording.
struct MediaFoundation {
    HMODULE platform = nullptr, readwrite = nullptr;
    decltype(&::MFStartup) startup = nullptr;
    decltype(&::MFShutdown) shutdown = nullptr;
    decltype(&::MFCreateMediaType) media_type = nullptr;
    decltype(&::MFCreateMemoryBuffer) memory_buffer = nullptr;
    decltype(&::MFCreateSample) sample = nullptr;
    decltype(&::MFCreateSinkWriterFromURL) writer = nullptr;
    bool load() {
        platform = LoadLibraryExW(L"mfplat.dll", nullptr, LOAD_LIBRARY_SEARCH_SYSTEM32);
        readwrite = LoadLibraryExW(L"mfreadwrite.dll", nullptr, LOAD_LIBRARY_SEARCH_SYSTEM32);
        if (!platform || !readwrite) return false;
        startup = reinterpret_cast<decltype(startup)>(GetProcAddress(platform, "MFStartup"));
        shutdown = reinterpret_cast<decltype(shutdown)>(GetProcAddress(platform, "MFShutdown"));
        media_type = reinterpret_cast<decltype(media_type)>(GetProcAddress(platform, "MFCreateMediaType"));
        memory_buffer = reinterpret_cast<decltype(memory_buffer)>(GetProcAddress(platform, "MFCreateMemoryBuffer"));
        sample = reinterpret_cast<decltype(sample)>(GetProcAddress(platform, "MFCreateSample"));
        writer = reinterpret_cast<decltype(writer)>(GetProcAddress(readwrite, "MFCreateSinkWriterFromURL"));
        return startup && shutdown && media_type && memory_buffer && sample && writer;
    }
    ~MediaFoundation() { if (readwrite) FreeLibrary(readwrite); if (platform) FreeLibrary(platform); }
};
HRESULT video_type(MediaFoundation &api, IMFMediaType **out, GUID subtype, uint32_t width, uint32_t height, uint32_t fps) {
    HRESULT hr = api.media_type(out);
    if (SUCCEEDED(hr)) hr = (*out)->SetGUID(MF_MT_MAJOR_TYPE, MFMediaType_Video);
    if (SUCCEEDED(hr)) hr = (*out)->SetGUID(MF_MT_SUBTYPE, subtype);
    if (SUCCEEDED(hr)) hr = (*out)->SetUINT32(MF_MT_INTERLACE_MODE, MFVideoInterlace_Progressive);
    if (SUCCEEDED(hr)) hr = MFSetAttributeSize(*out, MF_MT_FRAME_SIZE, width, height);
    if (SUCCEEDED(hr)) hr = MFSetAttributeRatio(*out, MF_MT_FRAME_RATE, fps, 1);
    if (SUCCEEDED(hr)) hr = MFSetAttributeRatio(*out, MF_MT_PIXEL_ASPECT_RATIO, 1, 1);
    return hr;
}
DWORD WINAPI worker(void *context) {
    auto *r = static_cast<Recorder *>(context);
    HRESULT hr = CoInitializeEx(nullptr, COINIT_MULTITHREADED);
    const bool com = SUCCEEDED(hr);
    bool mf = false;
    MediaFoundation api;
    if (SUCCEEDED(hr) && !api.load()) hr = HRESULT_FROM_WIN32(ERROR_MOD_NOT_FOUND);
    IMFSinkWriter *writer = nullptr;
    IMFMediaType *output = nullptr, *input = nullptr;
    DWORD stream = 0;
    if (SUCCEEDED(hr)) { hr = api.startup(MF_VERSION, MFSTARTUP_FULL); mf = SUCCEEDED(hr); }
    if (SUCCEEDED(hr)) hr = api.writer(r->path, nullptr, nullptr, &writer);
    if (SUCCEEDED(hr)) hr = video_type(api, &output, MFVideoFormat_H264, r->state.width, r->state.height, r->state.fps);
    const uint64_t bitrate = uint64_t(r->state.width) * r->state.height * r->state.fps;
    if (SUCCEEDED(hr)) hr = output->SetUINT32(MF_MT_AVG_BITRATE, (UINT32)(bitrate < 2000000 ? 2000000 : bitrate > 20000000 ? 20000000 : bitrate));
    if (SUCCEEDED(hr)) hr = writer->AddStream(output, &stream);
    if (SUCCEEDED(hr)) hr = video_type(api, &input, MFVideoFormat_RGB32, r->state.width, r->state.height, r->state.fps);
    if (SUCCEEDED(hr)) hr = input->SetUINT32(MF_MT_DEFAULT_STRIDE, r->state.width * 4);
    if (SUCCEEDED(hr)) hr = writer->SetInputMediaType(stream, input, nullptr);
    if (SUCCEEDED(hr)) hr = writer->BeginWriting();
    release(output); release(input);
    if (FAILED(hr)) fail(r, "initialize H.264 encoder", hr);
    AcquireSRWLockExclusive(&r->lock);
    r->ready = true;
    r->state.active = r->state.ok = SUCCEEDED(hr);
    WakeAllConditionVariable(&r->changed);
    ReleaseSRWLockExclusive(&r->lock);
    while (SUCCEEDED(hr)) {
        AcquireSRWLockExclusive(&r->lock);
        while (!r->count && !r->stopping) SleepConditionVariableSRW(&r->changed, &r->lock, INFINITE, 0);
        if (!r->count) { ReleaseSRWLockExclusive(&r->lock); break; }
        Frame frame = r->frames[r->head]; r->frames[r->head] = {};
        r->head = (r->head + 1) % capacity; --r->count;
        ReleaseSRWLockExclusive(&r->lock);
        IMFMediaBuffer *buffer = nullptr;
        IMFSample *sample = nullptr;
        const DWORD bytes = r->state.width * r->state.height * 4;
        hr = api.memory_buffer(bytes, &buffer);
        BYTE *dest = nullptr;
        if (SUCCEEDED(hr)) hr = buffer->Lock(&dest, nullptr, nullptr);
        if (SUCCEEDED(hr)) { memcpy(dest, frame.bytes, bytes); hr = buffer->Unlock(); }
        free(frame.bytes);
        if (SUCCEEDED(hr)) hr = buffer->SetCurrentLength(bytes);
        if (SUCCEEDED(hr)) hr = api.sample(&sample);
        if (SUCCEEDED(hr)) hr = sample->AddBuffer(buffer);
        if (SUCCEEDED(hr)) hr = sample->SetSampleTime(frame.time);
        if (SUCCEEDED(hr)) hr = sample->SetSampleDuration(10000000 / r->state.fps);
#ifdef ZENIT_RECORDING_CONTRACT_DELAY
        Sleep(80); // Contract-only deterministic encoder backpressure.
#endif
        if (SUCCEEDED(hr)) hr = writer->WriteSample(stream, sample);
        release(sample); release(buffer);
        if (FAILED(hr)) { fail(r, "encode video frame", hr); break; }
        AcquireSRWLockExclusive(&r->lock);
        ++r->state.frame_count;
        r->state.duration_ms = (frame.time + 10000000 / r->state.fps) / 10000;
        ReleaseSRWLockExclusive(&r->lock);
    }
    if (writer && SUCCEEDED(hr)) {
        hr = writer->Finalize();
        if (FAILED(hr)) fail(r, "finalize MP4", hr);
        else if (r->state.frame_count == 0) fail(r, "recording contains no frames", E_FAIL);
    }
    release(writer);
    if (mf) api.shutdown();
    if (com) CoUninitialize();
    WIN32_FILE_ATTRIBUTE_DATA info{};
    AcquireSRWLockExclusive(&r->lock);
    r->state.active = 0;
    if (GetFileAttributesExW(r->path, GetFileExInfoStandard, &info)) r->state.file_size = (uint64_t(info.nFileSizeHigh) << 32) | info.nFileSizeLow;
    ReleaseSRWLockExclusive(&r->lock);
    return 0;
}
LONGLONG now(Recorder *r) { LARGE_INTEGER value; QueryPerformanceCounter(&value); const LONGLONG elapsed = value.QuadPart - r->origin; return (elapsed / r->frequency) * 10000000 + (elapsed % r->frequency) * 10000000 / r->frequency; }
}
extern "C" void *zenit_recording_start(const char *path, uint32_t fps, uint32_t width, uint32_t height, ZenitRecordingState *out) {
    *out = {};
    if (!path || !*path || strlen(path) >= sizeof(out->path) || strlen(path) < 4 || _stricmp(path + strlen(path) - 4, ".mp4") != 0 || fps < 1 || fps > 120 || !width || !height || width > 8192 || height > 8192) {
        strcpy(out->error_message, "invalid recording path, fps or dimensions"); return nullptr;
    }
    auto *r = new(std::nothrow) Recorder;
    if (!r) { strcpy(out->error_message, "recording allocation failed"); return nullptr; }
    r->input_width = width; r->input_height = height;
    r->state.width = (width + 1) & ~1u; r->state.height = (height + 1) & ~1u; r->state.fps = fps;
    strcpy(r->state.path, path);
    if (!MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, path, -1, r->path, 768)) { strcpy(out->error_message, "invalid UTF-8 path"); delete r; return nullptr; }
    // Do not silently overwrite existing recordings.
    HANDLE reserve = CreateFileW(r->path, GENERIC_WRITE, 0, nullptr, CREATE_NEW, FILE_ATTRIBUTE_NORMAL, nullptr);
    if (reserve == INVALID_HANDLE_VALUE) { strcpy(out->error_message, "cannot create recording (path exists or is not writable)"); delete r; return nullptr; }
    CloseHandle(reserve);
    LARGE_INTEGER value; QueryPerformanceFrequency(&value); r->frequency = value.QuadPart;
    QueryPerformanceCounter(&value); r->origin = value.QuadPart;
    r->thread = CreateThread(nullptr, 0, worker, r, 0, nullptr);
    if (!r->thread) { DeleteFileW(r->path); strcpy(out->error_message, "cannot start recording worker"); delete r; return nullptr; }
    AcquireSRWLockExclusive(&r->lock);
    while (!r->ready) SleepConditionVariableSRW(&r->changed, &r->lock, INFINITE, 0);
    *out = r->state;
    ReleaseSRWLockExclusive(&r->lock);
    return r;
}
extern "C" void zenit_recording_status(void *context, ZenitRecordingState *out) {
    *out = {};
    if (!context) { out->ok = 1; return; }
    auto *r = static_cast<Recorder *>(context);
    AcquireSRWLockShared(&r->lock); *out = r->state; ReleaseSRWLockShared(&r->lock);
}
extern "C" int zenit_recording_due(void *context) {
    if (!context) return 0;
    auto *r = static_cast<Recorder *>(context);
    AcquireSRWLockShared(&r->lock);
    const bool due = r->state.active && !r->stopping && (r->last < 0 || now(r) - r->last >= 10000000 / r->state.fps);
    ReleaseSRWLockShared(&r->lock);
    return due;
}
extern "C" int zenit_recording_append(void *context, const ZenitRecordingFrame *frame) {
    if (!context || !frame || !frame->bytes) return 0;
    auto *r = static_cast<Recorder *>(context);
    if (frame->width != r->input_width || frame->height != r->input_height || uint64_t(frame->stride) < uint64_t(frame->width) * 4) {
        fail(r, "window resized during recording", E_INVALIDARG); return 0;
    }
    AcquireSRWLockExclusive(&r->lock);
    if (!r->state.active || r->stopping) { ReleaseSRWLockExclusive(&r->lock); return 0; }
    const LONGLONG timestamp = now(r);
    if (r->last >= 0 && timestamp - r->last < 10000000 / r->state.fps) { ReleaseSRWLockExclusive(&r->lock); return 1; }
    if (r->count == capacity) { ++r->state.dropped_frames; ReleaseSRWLockExclusive(&r->lock); return 1; }
    auto *bytes = static_cast<uint8_t *>(calloc(size_t(r->state.width) * r->state.height, 4));
    if (!bytes) { ++r->state.dropped_frames; ReleaseSRWLockExclusive(&r->lock); return 1; }
    for (uint32_t y = 0; y < frame->height; ++y) memcpy(bytes + size_t(y) * r->state.width * 4, frame->bytes + size_t(y) * frame->stride, size_t(frame->width) * 4);
    if (r->first < 0) r->first = timestamp;
    r->frames[(r->head + r->count) % capacity] = {bytes, timestamp - r->first};
    ++r->count; r->last = timestamp;
    WakeConditionVariable(&r->changed);
    ReleaseSRWLockExclusive(&r->lock);
    return 1;
}
extern "C" void zenit_recording_stop(void *context, ZenitRecordingState *out) {
    if (!context) { *out = {}; out->ok = 1; return; }
    auto *r = static_cast<Recorder *>(context);
    AcquireSRWLockExclusive(&r->lock); r->stopping = true; WakeAllConditionVariable(&r->changed); ReleaseSRWLockExclusive(&r->lock);
    WaitForSingleObject(r->thread, INFINITE);
    zenit_recording_status(r, out);
}
extern "C" void zenit_recording_destroy(void *context) {
    if (!context) return;
    auto *r = static_cast<Recorder *>(context);
    ZenitRecordingState state; zenit_recording_stop(r, &state);
    CloseHandle(r->thread);
    for (auto &frame : r->frames) free(frame.bytes);
    delete r;
}
extern "C" void zenit_recording_fail(void *context, const char *message) {
    if (context) fail(static_cast<Recorder *>(context), message, E_FAIL);
}
