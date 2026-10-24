/* Asynchronous D3D11 timestamp/disjoint sampling. Included by d3d11_probe.c.
   Only complete, non-disjoint GPU intervals enter the 120-frame P95 ring.
   Reset generations discard in-flight samples from the previous scenario. */
static void timing_release(ZenitD3D11Probe *p) {
    for (unsigned i=0;i<TIMING_QUERY_COUNT;++i) {
        ZenitTimingQuery *q=&p->timing_queries[i];
        if(q->disjoint) ID3D11Query_Release(q->disjoint);
        if(q->start) ID3D11Query_Release(q->start);
        if(q->end) ID3D11Query_Release(q->end);
        *q=(ZenitTimingQuery){0};
    }
    p->timing_enabled=p->gpu_queries_enabled=0;
}
static void timing_poll(ZenitD3D11Probe *p) {
    for (unsigned i=0;i<TIMING_QUERY_COUNT;++i) {
        ZenitTimingQuery *q=&p->timing_queries[i];
        if(!q->pending) continue;
        D3D11_QUERY_DATA_TIMESTAMP_DISJOINT d={0};
        UINT64 start=0,end=0;
        HRESULT hr=ID3D11DeviceContext_GetData(p->context,(ID3D11Asynchronous *)q->disjoint,&d,sizeof(d),D3D11_ASYNC_GETDATA_DONOTFLUSH);
        if(hr==S_FALSE) continue;
        if(SUCCEEDED(hr)) hr=ID3D11DeviceContext_GetData(p->context,(ID3D11Asynchronous *)q->start,&start,sizeof(start),D3D11_ASYNC_GETDATA_DONOTFLUSH);
        if(hr==S_FALSE) continue;
        if(SUCCEEDED(hr)) hr=ID3D11DeviceContext_GetData(p->context,(ID3D11Asynchronous *)q->end,&end,sizeof(end),D3D11_ASYNC_GETDATA_DONOTFLUSH);
        if(hr==S_FALSE) continue;
        q->pending=0;
        if(q->generation!=p->timing_generation || !q->valid) continue;
        if(FAILED(hr) || !d.Frequency || end<=start) { ++p->timing_failed; continue; }
        if(d.Disjoint) {
            if(!p->timing_disjoint) fprintf(stderr,"[windows-gpu-timing] rejected disjoint=1 frequency=%llu generation=%llu\n",(unsigned long long)d.Frequency,(unsigned long long)p->timing_generation);
            ++p->timing_disjoint;
            continue;
        }
        double us=(double)(end-start)*1000000.0/(double)d.Frequency;
        if(!isfinite(us) || us<=0 || us>=(double)UINT64_MAX) { ++p->timing_failed; continue; }
        q->sample.gpu_execute_us=(uint64_t)ceil(us);
        if(q->sequence>p->last_gpu_sequence) { p->last_gpu=q->sample; p->last_gpu_sequence=q->sequence; }
        p->timings[p->timing_head]=q->sample;
        p->timing_head=(p->timing_head+1)%TIMING_SAMPLE_COUNT;
        if(p->timing_len<TIMING_SAMPLE_COUNT) ++p->timing_len;
    }
}
static ZenitTimingQuery *timing_begin(ZenitD3D11Probe *p) {
    if(!p->gpu_queries_enabled) return NULL;
    timing_poll(p);
    for(unsigned i=0;i<TIMING_QUERY_COUNT;++i) {
        ZenitTimingQuery *q=&p->timing_queries[i];
        if(q->pending) continue;
        q->sample=p->cpu_phases;
        q->generation=p->timing_generation;
        q->sequence=++p->timing_sequence;
        q->valid=0;
        ID3D11DeviceContext_Begin(p->context,(ID3D11Asynchronous *)q->disjoint);
        ID3D11DeviceContext_End(p->context,(ID3D11Asynchronous *)q->start);
        return q;
    }
    return NULL; /* GPU backlog: never reuse an unfinished query or block. */
}
static void timing_end(ZenitD3D11Probe *p,ZenitTimingQuery *q,int valid) {
    if(!q) return;
    ID3D11DeviceContext_End(p->context,(ID3D11Asynchronous *)q->end);
    ID3D11DeviceContext_End(p->context,(ID3D11Asynchronous *)q->disjoint);
    q->pending=1;
    q->valid=valid;
}
static void timing_finish_cpu(ZenitD3D11Probe *p,ZenitTimingQuery *q,LARGE_INTEGER start,LARGE_INTEGER draw_end,int valid) {
    if(valid) ++p->timing_frames;
    if(!p->timing_enabled) { p->cpu_phases=(ZenitFrameTiming){0}; return; }
    LARGE_INTEGER end,freq;
    QueryPerformanceCounter(&end); QueryPerformanceFrequency(&freq);
    uint64_t paint=(uint64_t)((double)(draw_end.QuadPart-start.QuadPart)*1000000.0/freq.QuadPart);
    uint64_t total=(uint64_t)((double)(end.QuadPart-start.QuadPart)*1000000.0/freq.QuadPart);
    ZenitFrameTiming sample=p->cpu_phases;
    uint64_t prep=sample.layout_us+sample.render_gen_us+sample.gpu_encode_us;
    sample.cpu_frame_us=prep+paint;
    sample.total_frame_us=prep+total;
    sample.gpu_encode_us+=paint;
    p->cpu_phases=(ZenitFrameTiming){0};
    if(q) { q->sample=sample; q->valid=valid; }
    if(!valid) return;
    p->cpu_timings[p->cpu_timing_head]=sample;
    p->cpu_timing_head=(p->cpu_timing_head+1)%TIMING_SAMPLE_COUNT;
    if(p->cpu_timing_len<TIMING_SAMPLE_COUNT) ++p->cpu_timing_len;
}
void zenit_d3d11_probe_set_cpu_timing(ZenitD3D11Probe *p,uint64_t layout,uint64_t render,uint64_t encode) {
    p->cpu_phases=(ZenitFrameTiming){.layout_us=layout,.render_gen_us=render,.gpu_encode_us=encode};
}
void zenit_d3d11_probe_reset_timing(ZenitD3D11Probe *p) {
    if(!p) return;
    ++p->timing_generation;
    p->timing_len=p->timing_head=p->cpu_timing_len=p->cpu_timing_head=0;
    p->timing_disjoint=p->timing_failed=0;
    p->last_gpu=(ZenitFrameTiming){0};
    if(p->timing_enabled) return;
    D3D11_QUERY_DESC desc={D3D11_QUERY_TIMESTAMP_DISJOINT,0};
    HRESULT hr=S_OK;
    for(unsigned i=0;i<TIMING_QUERY_COUNT && SUCCEEDED(hr);++i) {
        ZenitTimingQuery *q=&p->timing_queries[i];
        desc.Query=D3D11_QUERY_TIMESTAMP_DISJOINT;
        hr=ID3D11Device_CreateQuery(p->device,&desc,&q->disjoint);
        desc.Query=D3D11_QUERY_TIMESTAMP;
        if(SUCCEEDED(hr)) hr=ID3D11Device_CreateQuery(p->device,&desc,&q->start);
        if(SUCCEEDED(hr)) hr=ID3D11Device_CreateQuery(p->device,&desc,&q->end);
    }
    if(FAILED(hr)) {
        timing_release(p);
        p->timing_enabled=1; /* CPU timing remains available without GPU queries. */
        fprintf(stderr,"[windows-gpu-timing] unavailable hr=0x%08lx\n",(unsigned long)hr);
        return;
    }
    p->timing_enabled=p->gpu_queries_enabled=1;
    fprintf(stderr,"[windows-gpu-timing] enabled driver=%d queries=%u\n",p->driver,TIMING_QUERY_COUNT);
}
static int timing_compare(const void *a,const void *b) {
    uint64_t x=*(const uint64_t *)a,y=*(const uint64_t *)b;
    return x<y ? -1 : x>y;
}
void zenit_d3d11_probe_get_timing(ZenitD3D11Probe *p,ZenitTimingStats *out) {
    *out=(ZenitTimingStats){0};
    if(!p) return;
    timing_poll(p);
    out->frame_count=p->timing_frames;
    out->query_supported=p->timing_enabled ? (p->gpu_queries_enabled ? 1 : 2) : 0;
    out->timing_samples=p->timing_len;
    out->cpu_timing_samples=p->cpu_timing_len;
    out->disjoint_samples=p->timing_disjoint;
    out->failed_samples=p->timing_failed;
    for(unsigned i=0;i<TIMING_QUERY_COUNT;++i) if(p->timing_queries[i].pending && p->timing_queries[i].generation==p->timing_generation) ++out->pending_queries;
    if(p->cpu_timing_len) out->last=p->cpu_timings[(p->cpu_timing_head+TIMING_SAMPLE_COUNT-1)%TIMING_SAMPLE_COUNT];
    out->last.gpu_execute_us=p->last_gpu.gpu_execute_us;
    uint64_t values[TIMING_SAMPLE_COUNT];
    uint64_t *results[3]={&out->gpu_p95_us,&out->cpu_p95_us,&out->total_p95_us};
    for(unsigned field=0;field<3;++field) {
        unsigned count=field==0 ? p->timing_len : p->cpu_timing_len;
        if(!count) continue;
        for(unsigned i=0;i<count;++i) {
            ZenitFrameTiming *s=field==0 ? &p->timings[i] : &p->cpu_timings[i];
            values[i]=field==0 ? s->gpu_execute_us : field==1 ? s->cpu_frame_us : s->total_frame_us;
        }
        qsort(values,count,sizeof(uint64_t),timing_compare);
        *results[field]=values[(95*count+99)/100-1];
    }
}
