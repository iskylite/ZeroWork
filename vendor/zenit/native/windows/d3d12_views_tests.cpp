// Native bridge for the shader ownership contract. All recording/submission is
// production code; no test-only PSO, descriptor heap, barrier or dispatch path.
#include "d3d12_resources.h"
#include <windows.h>
extern "C" void zenit_d12_test_shader_dispatch(ZenitD12Device *owner, ZenitD12Queue *queue,
    ZenitD12Shader *shader, ZenitD12Buffer *output) {
    ZenitD12LayoutBinding binding={0,0,3,1,4};
    ZenitD12PipelineLayout *layout=nullptr;
    if (zenit_d12_pipeline_layout_create(owner,1,&binding,1,&layout)) ExitProcess(16);
    ZenitD12ComputePipeline *pipeline=nullptr;
    if (zenit_d12_compute_pipeline_create(owner,layout,shader,&pipeline)) ExitProcess(17);
    ZenitD12BindingEntry entry={}; entry.buffer=output; entry.size=16; entry.stride=4;
    ZenitD12BindGroup *group=nullptr;
    if (zenit_d12_bind_group_create(owner,layout,0,&entry,1,&group)) ExitProcess(18);
    ZenitD12Commands *command=nullptr;
    if (zenit_d12_commands_create(owner,&command)) ExitProcess(19);
    if (zenit_d12_commands_dispatch(command,pipeline,&group,1,1,1,1)) ExitProcess(20);
    zenit_d12_bind_group_release(group); zenit_d12_compute_pipeline_release(pipeline);
    zenit_d12_pipeline_layout_release(layout);
    if (zenit_d12_commands_finish(command)) ExitProcess(21);
    uint64_t serial=0;
    if (zenit_d12_queue_submit(queue,command,&serial)) ExitProcess(22);
    zenit_d12_commands_release(command);
    // On timeout terminate before releasing any resources still in flight.
    if (zenit_d12_queue_wait(queue,serial,5000)) ExitProcess(23);
}
