#include "recording_bridge.h"
#include <windows.h>
#include <stdio.h>
#include <string.h>
#include <vector>
#define REQUIRE(x) do { if (!(x)) { fprintf(stderr,"FAIL line=%d %s error=%s\n",__LINE__,#x,state.error_message); return 1; } } while(0)
int main(int argc, char **argv) {
    if (argc > 1) { freopen(argv[1], "w", stdout); freopen(argv[1], "a", stderr); }
    ZenitRecordingState state{};
    REQUIRE(!zenit_recording_start("",30,320,240,&state));
    REQUIRE(!state.ok && !state.active && state.error_message[0]);
    REQUIRE(!zenit_recording_start("C:\\Windows\\Temp\\invalid-fps.mp4",0,320,240,&state));
    REQUIRE(!zenit_recording_start("recording.wmv",30,320,240,&state));
    char path[768];
    snprintf(path,sizeof(path),"C:\\Windows\\Temp\\zenit-recording-contract-%lu-%llu.mp4",GetCurrentProcessId(),GetTickCount64());
    void *recorder = zenit_recording_start(path,120,321,241,&state);
    REQUIRE(recorder && state.ok && state.active && state.width==322 && state.height==242);
    std::vector<uint8_t> pixels(321*241*4);
    for (unsigned y=0; y<241; ++y) for (unsigned x=0; x<321; ++x) {
        size_t p=(y*321+x)*4; pixels[p]=y<120?0:255; pixels[p+1]=x<160?0:255; pixels[p+2]=y<120?255:0; pixels[p+3]=255;
    }
    ZenitRecordingFrame frame{pixels.data(),321,241,321*4};
    unsigned submitted=0;
    ULONGLONG start=GetTickCount64();
    for(unsigned i=0;i<40;++i) { REQUIRE(zenit_recording_append(recorder,&frame)); ++submitted; Sleep(9); }
    REQUIRE(GetTickCount64()-start < 1800); // 40 * 80ms encoder must not block producer.
    zenit_recording_stop(recorder,&state);
    REQUIRE(state.ok && !state.active && state.frame_count>0 && state.frame_count<submitted && state.dropped_frames>0 && state.file_size>1000);
    auto original=state;
    zenit_recording_stop(recorder,&state);
    REQUIRE(state.file_size==original.file_size && state.frame_count==original.frame_count);
    zenit_recording_destroy(recorder);
    REQUIRE(!zenit_recording_start(path,30,320,240,&state));
    REQUIRE(!state.ok && state.error_message[0]);
    char empty_path[768]; snprintf(empty_path,sizeof(empty_path),"%s.empty.mp4",path);
    recorder = zenit_recording_start(empty_path,30,320,240,&state);
    REQUIRE(recorder && state.ok);
    zenit_recording_stop(recorder,&state);
    REQUIRE(!state.ok && !state.active && state.error_message[0]);
    zenit_recording_destroy(recorder);
    printf("PASS bounded asynchronous queue, odd-size padding, finalize, idempotent stop, invalid arguments, no overwrite\n");
    printf("VIDEO %s\nFRAMES %llu DROPPED %llu BYTES %llu\n", path, original.frame_count, original.dropped_frames, original.file_size);
    return 0;
}
