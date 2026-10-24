#pragma once
#include <d3dcompiler.h>
#include <new>

// Private queue and resources keep the lazy probe independent of caller work.
struct ZenitAtomicProbe {
    ID3D12CommandQueue *queue=nullptr;
    ID3D12CommandAllocator *allocator=nullptr;
    ID3D12GraphicsCommandList *list=nullptr;
    ID3D12RootSignature *root=nullptr;
    ID3D12PipelineState *pipeline=nullptr;
    ID3D12DescriptorHeap *heap=nullptr;
    ID3D12Resource *buffers[2]={}, *upload=nullptr, *readback=nullptr;
    ID3D12Fence *fence=nullptr;
    ID3DBlob *code=nullptr, *signature=nullptr;
    HANDLE event=nullptr;
    bool submitted=false;
    ~ZenitAtomicProbe() {
        if(event) CloseHandle(event);
        if(list) list->Release();
        if(allocator) allocator->Release();
        if(pipeline) pipeline->Release();
        if(root) root->Release();
        if(heap) heap->Release();
        for(auto buffer:buffers) if(buffer) buffer->Release();
        if(upload) upload->Release();
        if(readback) readback->Release();
        if(fence) fence->Release();
        if(queue) queue->Release();
        if(code) code->Release();
        if(signature) signature->Release();
    }
};

static HRESULT zenit_atomic_probe(ID3D12Device *device, bool raw, ZenitAtomicProbe *p, bool *correct) {
    const char *source=raw ?
        "RWByteAddressBuffer result[2]:register(u0); [numthreads(32,1,1)] void main(uint3 id:SV_DispatchThreadID){result[NonUniformResourceIndex(id.x%2)].InterlockedAdd(id.x*4,100);}" :
        "RWStructuredBuffer<uint> result[2]:register(u0); [numthreads(32,1,1)] void main(uint3 id:SV_DispatchThreadID){InterlockedAdd(result[NonUniformResourceIndex(id.x%2)][id.x],100);}";
    HRESULT hr=D3DCompile(source,strlen(source),nullptr,nullptr,nullptr,"main","cs_5_1",D3DCOMPILE_ENABLE_STRICTNESS|D3DCOMPILE_OPTIMIZATION_LEVEL3,0,&p->code,nullptr);
    if(FAILED(hr)) return hr;
    D3D12_DESCRIPTOR_RANGE range={D3D12_DESCRIPTOR_RANGE_TYPE_UAV,2,0,0,0};
    D3D12_ROOT_PARAMETER parameter={};
    parameter.ParameterType=D3D12_ROOT_PARAMETER_TYPE_DESCRIPTOR_TABLE;
    parameter.DescriptorTable={1,&range};
    D3D12_ROOT_SIGNATURE_DESC root={1,&parameter,0,nullptr,D3D12_ROOT_SIGNATURE_FLAG_NONE};
    hr=D3D12SerializeRootSignature(&root,D3D_ROOT_SIGNATURE_VERSION_1,&p->signature,nullptr);
    if(FAILED(hr)) return hr;
    hr=device->CreateRootSignature(0,p->signature->GetBufferPointer(),p->signature->GetBufferSize(),IID_ID3D12RootSignature,(void**)&p->root);
    if(FAILED(hr)) return hr;
    D3D12_COMPUTE_PIPELINE_STATE_DESC pipeline={};
    pipeline.pRootSignature=p->root;
    pipeline.CS={p->code->GetBufferPointer(),p->code->GetBufferSize()};
    hr=device->CreateComputePipelineState(&pipeline,IID_ID3D12PipelineState,(void**)&p->pipeline);
    if(FAILED(hr)) return hr;
    D3D12_COMMAND_QUEUE_DESC queue={};
    hr=device->CreateCommandQueue(&queue,IID_ID3D12CommandQueue,(void**)&p->queue);
    if(FAILED(hr)) return hr;
    hr=device->CreateCommandAllocator(D3D12_COMMAND_LIST_TYPE_DIRECT,IID_ID3D12CommandAllocator,(void**)&p->allocator);
    if(FAILED(hr)) return hr;
    hr=device->CreateCommandList(0,D3D12_COMMAND_LIST_TYPE_DIRECT,p->allocator,p->pipeline,IID_ID3D12GraphicsCommandList,(void**)&p->list);
    if(FAILED(hr)) return hr;
    D3D12_DESCRIPTOR_HEAP_DESC heap={D3D12_DESCRIPTOR_HEAP_TYPE_CBV_SRV_UAV,2,D3D12_DESCRIPTOR_HEAP_FLAG_SHADER_VISIBLE,0};
    hr=device->CreateDescriptorHeap(&heap,IID_ID3D12DescriptorHeap,(void**)&p->heap);
    if(FAILED(hr)) return hr;
    D3D12_RESOURCE_DESC buffer={};
    buffer.Dimension=D3D12_RESOURCE_DIMENSION_BUFFER; buffer.Width=256;
    buffer.Height=1; buffer.DepthOrArraySize=1; buffer.MipLevels=1; buffer.SampleDesc.Count=1;
    buffer.Layout=D3D12_TEXTURE_LAYOUT_ROW_MAJOR;
    D3D12_HEAP_PROPERTIES properties={}; properties.Type=D3D12_HEAP_TYPE_UPLOAD;
    hr=device->CreateCommittedResource(&properties,D3D12_HEAP_FLAG_NONE,&buffer,D3D12_RESOURCE_STATE_GENERIC_READ,nullptr,IID_ID3D12Resource,(void**)&p->upload);
    if(FAILED(hr)) return hr;
    void *mapping=nullptr; D3D12_RANGE empty={};
    hr=p->upload->Map(0,&empty,&mapping); if(FAILED(hr)) return hr;
    memset(mapping,0,256); p->upload->Unmap(0,nullptr);
    properties.Type=D3D12_HEAP_TYPE_READBACK;
    hr=device->CreateCommittedResource(&properties,D3D12_HEAP_FLAG_NONE,&buffer,D3D12_RESOURCE_STATE_COPY_DEST,nullptr,IID_ID3D12Resource,(void**)&p->readback);
    if(FAILED(hr)) return hr;
    buffer.Width=128; buffer.Flags=D3D12_RESOURCE_FLAG_ALLOW_UNORDERED_ACCESS;
    properties.Type=D3D12_HEAP_TYPE_DEFAULT;
    auto handle=p->heap->GetCPUDescriptorHandleForHeapStart();
    for(unsigned i=0;i<2;++i) {
        hr=device->CreateCommittedResource(&properties,D3D12_HEAP_FLAG_NONE,&buffer,D3D12_RESOURCE_STATE_COPY_DEST,nullptr,IID_ID3D12Resource,(void**)&p->buffers[i]);
        if(FAILED(hr)) return hr;
        D3D12_UNORDERED_ACCESS_VIEW_DESC view={}; view.ViewDimension=D3D12_UAV_DIMENSION_BUFFER;
        view.Format=raw?DXGI_FORMAT_R32_TYPELESS:DXGI_FORMAT_UNKNOWN;
        view.Buffer.NumElements=32; view.Buffer.StructureByteStride=raw?0:4;
        view.Buffer.Flags=raw?D3D12_BUFFER_UAV_FLAG_RAW:D3D12_BUFFER_UAV_FLAG_NONE;
        device->CreateUnorderedAccessView(p->buffers[i],nullptr,&view,handle);
        handle.ptr+=device->GetDescriptorHandleIncrementSize(D3D12_DESCRIPTOR_HEAP_TYPE_CBV_SRV_UAV);
        p->list->CopyBufferRegion(p->buffers[i],0,p->upload,0,128);
        D3D12_RESOURCE_BARRIER barrier={}; barrier.Type=D3D12_RESOURCE_BARRIER_TYPE_TRANSITION;
        barrier.Transition={p->buffers[i],D3D12_RESOURCE_BARRIER_ALL_SUBRESOURCES,D3D12_RESOURCE_STATE_COPY_DEST,D3D12_RESOURCE_STATE_UNORDERED_ACCESS};
        p->list->ResourceBarrier(1,&barrier);
    }
    p->list->SetComputeRootSignature(p->root); p->list->SetDescriptorHeaps(1,&p->heap);
    p->list->SetComputeRootDescriptorTable(0,p->heap->GetGPUDescriptorHandleForHeapStart());
    p->list->Dispatch(1,1,1);
    for(unsigned i=0;i<2;++i) {
        D3D12_RESOURCE_BARRIER barrier={}; barrier.Type=D3D12_RESOURCE_BARRIER_TYPE_TRANSITION;
        barrier.Transition={p->buffers[i],D3D12_RESOURCE_BARRIER_ALL_SUBRESOURCES,D3D12_RESOURCE_STATE_UNORDERED_ACCESS,D3D12_RESOURCE_STATE_COPY_SOURCE};
        p->list->ResourceBarrier(1,&barrier);
        p->list->CopyBufferRegion(p->readback,i*128,p->buffers[i],0,128);
    }
    hr=p->list->Close(); if(FAILED(hr)) return hr;
    hr=device->CreateFence(0,D3D12_FENCE_FLAG_NONE,IID_ID3D12Fence,(void**)&p->fence);
    if(FAILED(hr)) return hr;
    p->event=CreateEventW(nullptr,FALSE,FALSE,nullptr); if(!p->event) return HRESULT_FROM_WIN32(GetLastError());
    ID3D12CommandList *lists[]={p->list}; p->queue->ExecuteCommandLists(1,lists); p->submitted=true;
    hr=p->queue->Signal(p->fence,1); if(FAILED(hr)) return hr;
    hr=p->fence->SetEventOnCompletion(1,p->event); if(FAILED(hr)) return hr;
    DWORD wait=WaitForSingleObject(p->event,30000);
    if(wait!=WAIT_OBJECT_0) return wait==WAIT_TIMEOUT?HRESULT_FROM_WIN32(WAIT_TIMEOUT):HRESULT_FROM_WIN32(GetLastError());
    hr=device->GetDeviceRemovedReason(); if(FAILED(hr)) return hr;
    D3D12_RANGE read={0,256}; hr=p->readback->Map(0,&read,&mapping); if(FAILED(hr)) return hr;
    *correct=true;
    for(unsigned i=0;i<2;++i) for(unsigned x=0;x<32;++x)
        if(((uint32_t*)mapping)[i*32+x]!=(i==x%2?100u:0u)) *correct=false;
    p->readback->Unmap(0,&empty);
    return S_OK;
}
