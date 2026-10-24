// Native acceptance for the D3D11 implementation of the shared renderer ABI.
// Exact pixels, padded readback, command-owned snapshots, and regional clears.
#include "d3d12_resources.h"
#include <d3d11.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <windows.h>
#define CHECK(expr)                                                            \
  do {                                                                         \
    if (!(expr)) {                                                             \
      fprintf(stderr, "D3D11 contract failed line %d: %s\n", __LINE__, #expr); \
      return 1;                                                                \
    }                                                                          \
  } while (0)
template <class T> struct DiagnosticCom {
  T *p = nullptr;
  ~DiagnosticCom() {
    if (p)
      p->Release();
  }
};
extern "C" uint32_t
zenit_d11_commands_storage_snapshot_count(ZenitD12Commands *);

extern "C" uint64_t zenit_d11_uniform_buffer_creations(ZenitD12Device *);
extern "C" void zenit_d11_clear_uniform_cache(ZenitD12Device *);
// The pixel result catches stale snapshots after overwrite; the distinct-count
// checks independently prove repeated identical bindings reuse GPU storage.
static int check_storage_snapshots(ZenitD12Device *device, ZenitD12Queue *queue,
                                   bool gpu_only, bool compute_blue = false, bool uniform = false, bool evict_uniforms = false) {
  const char storage_source[] =
      "StructuredBuffer<float4> colors : register(t0, space0);\n"
      "float4 vs(uint id : SV_VertexID) : SV_Position {\n"
      "float2 p = float2((id << 1) & 2, id & 2);\n"
      "return float4(p * float2(2, -2) + float2(-1, 1), 0, 1); }\n"
      "float4 ps() : SV_Target { return colors[0]; }\n";
  const char uniform_source[] =
      "cbuffer C : register(b0, space0) { float4 color; };\n"
      "float4 vs(uint id : SV_VertexID) : SV_Position {\n"
      "float2 p = float2((id << 1) & 2, id & 2);\n"
      "return float4(p * float2(2, -2) + float2(-1, 1), 0, 1); }\n"
      "float4 ps() : SV_Target { return color; }\n";
  const char *source = uniform ? uniform_source : storage_source;
  ZenitD12Shader *vs = nullptr, *ps = nullptr;
  char *diagnostic = nullptr;
  size_t diagnostic_size = 0;
  CHECK(zenit_d12_shader_compile(source, strlen(source), "vs", 1, &vs,
                                 &diagnostic, &diagnostic_size) == 0);
  zenit_d12_shader_diagnostic_free(diagnostic);
  diagnostic = nullptr;
  CHECK(zenit_d12_shader_compile(source, strlen(source), "ps", 2, &ps,
                                 &diagnostic, &diagnostic_size) == 0);
  zenit_d12_shader_diagnostic_free(diagnostic);
  ZenitD12LayoutBinding binding = {};
  binding.kind = uniform ? 0 : 2;
  binding.count = 1;
  binding.visibility = 2;
  binding.min_size = 16;
  ZenitD12PipelineLayout *layout = nullptr;
  CHECK(zenit_d12_pipeline_layout_create(device, 1, &binding, 1, &layout) == 0);
  ZenitD12ColorTarget target = {};
  target.format = 28;
  target.write_mask = 15;
  target.color_src = target.alpha_src = D3D11_BLEND_ONE;
  target.color_dst = target.alpha_dst = D3D11_BLEND_ZERO;
  target.color_op = target.alpha_op = D3D11_BLEND_OP_ADD;
  ZenitD12RenderDescriptor descriptor = {};
  descriptor.targets = &target;
  descriptor.target_count = 1;
  descriptor.topology = D3D11_PRIMITIVE_TOPOLOGY_TRIANGLELIST;
  descriptor.cull = D3D11_CULL_NONE;
  descriptor.fill = D3D11_FILL_SOLID;
  descriptor.depth_clip = 1;
  descriptor.sample_mask = UINT32_MAX;
  descriptor.samples = 1;
  ZenitD12RenderPipeline *pipeline = nullptr;
  CHECK(zenit_d12_render_pipeline_create(device, layout, vs, ps, &descriptor,
                                         &pipeline) == 0);
  zenit_d12_shader_release(vs);
  zenit_d12_shader_release(ps);
  ZenitD12Texture *texture = nullptr;
  CHECK(zenit_d12_texture_create(device, 2, 4, 4, 1, 1, 28, 1 | 16, 1,
                                 &texture) == 0);
  ZenitD12Buffer *storage = nullptr, *readback = nullptr, *upload = nullptr;
  CHECK(zenit_d12_buffer_create(device, 32, (gpu_only ? 8 : 2) | (uniform ? 64 : 128),
                                &storage) == 0);
  if (gpu_only)
    CHECK(zenit_d12_buffer_create(device, 32, 2 | 4, &upload) == 0);
  CHECK(zenit_d12_buffer_create(device, 1024, 1 | 8, &readback) == 0);
  auto mapped = (float *)zenit_d12_buffer_mapping(gpu_only ? upload : storage);
  CHECK(mapped);
  const float red[4] = {1, 0, 0, 1}, blue[4] = {0, 0, 1, 1};
  memset(mapped, 0, 32);
  memcpy(mapped + 4, red, sizeof(red));
  ZenitD12BindingEntry entry = {};
  entry.buffer = storage;
  entry.offset = 16;
  entry.size = 16;
  entry.stride = uniform ? 0 : 16;
  ZenitD12BindGroup *group = nullptr;
  CHECK(zenit_d12_bind_group_create(device, layout, 0, &entry, 1, &group) == 0);
  ZenitD12PipelineLayout *compute_layout = nullptr;
  ZenitD12ComputePipeline *compute_pipeline = nullptr;
  ZenitD12BindGroup *compute_group = nullptr;
  if (compute_blue) {
    CHECK(gpu_only);
    const char compute_source[] =
        "RWStructuredBuffer<float4> colors : register(u0, space0);\n"
        "[numthreads(1,1,1)] void cs(uint3 id : SV_DispatchThreadID) {\n"
        "colors[0] = float4(0,0,1,1); }\n";
    ZenitD12Shader *cs = nullptr;
    diagnostic = nullptr;
    CHECK(zenit_d12_shader_compile(compute_source, sizeof(compute_source) - 1,
                                   "cs", 3, &cs, &diagnostic,
                                   &diagnostic_size) == 0);
    zenit_d12_shader_diagnostic_free(diagnostic);
    ZenitD12LayoutBinding writable = binding;
    writable.kind = 3;
    writable.visibility = 4;
    CHECK(zenit_d12_pipeline_layout_create(device, 1, &writable, 1,
                                           &compute_layout) == 0);
    CHECK(zenit_d12_compute_pipeline_create(device, compute_layout, cs,
                                            &compute_pipeline) == 0);
    zenit_d12_shader_release(cs);
    CHECK(zenit_d12_bind_group_create(device, compute_layout, 0, &entry, 1,
                                      &compute_group) == 0);
  }
  ZenitD12Commands *commands = nullptr;
  CHECK(zenit_d12_commands_create(device, &commands) == 0);
  if (gpu_only)
    CHECK(zenit_d12_commands_copy(commands, upload, 0, storage, 0, 32) == 0);
  ZenitD12ColorAttachment attachment = {};
  attachment.texture = texture;
  attachment.load_op = 1;
  ZenitD12RenderPass *pass = nullptr;
  CHECK(zenit_d12_render_pass_begin(commands, &attachment, 1, nullptr, &pass) ==
        0);
  ZenitD12Draw draw = {};
  draw.vertices = 3;
  draw.instances = 1;
  draw.width = 1;
  draw.height = 4;
  draw.groups = &group;
  draw.group_count = 1;
  CHECK(zenit_d12_render_pass_draw(pass, pipeline, &draw) == 0);
  CHECK(zenit_d11_commands_storage_snapshot_count(commands) == 1);
  // Uniforms in different upload-ring ranges with equal contents must reuse
  // one snapshot; later overwrite must still preserve the earlier red draw.
  if (uniform) {
    memcpy(mapped, red, sizeof(red));
    zenit_d12_bind_group_release(group);
    entry.offset = 0;
    CHECK(zenit_d12_bind_group_create(device, layout, 0, &entry, 1, &group) == 0);
  }
  draw.x = 1;
  CHECK(zenit_d12_render_pass_draw(pass, pipeline, &draw) == 0);
  CHECK(zenit_d11_commands_storage_snapshot_count(commands) == 1);
  memcpy(mapped + (uniform ? 0 : 4), blue, sizeof(blue));
  if (gpu_only) {
    CHECK(zenit_d12_render_pass_end(pass) == 0);
    if (compute_blue)
      CHECK(zenit_d12_commands_dispatch(commands, compute_pipeline,
                                        &compute_group, 1, 1, 1, 1) == 0);
    else
      CHECK(zenit_d12_commands_copy(commands, upload, 16, storage, 16, 16) ==
            0);
    attachment.load_op = 0;
    CHECK(zenit_d12_render_pass_begin(commands, &attachment, 1, nullptr,
                                      &pass) == 0);
  }
  draw.x = 2;
  CHECK(zenit_d12_render_pass_draw(pass, pipeline, &draw) == 0);
  CHECK(zenit_d11_commands_storage_snapshot_count(commands) == 2);
  memcpy(mapped + (uniform ? 0 : 4), red, sizeof(red));
  if (gpu_only) {
    CHECK(zenit_d12_render_pass_end(pass) == 0);
    CHECK(zenit_d12_commands_copy(commands, upload, 16, storage, 16, 16) == 0);
    CHECK(zenit_d12_render_pass_begin(commands, &attachment, 1, nullptr,
                                      &pass) == 0);
  }
  draw.x = 3;
  CHECK(zenit_d12_render_pass_draw(pass, pipeline, &draw) == 0);
  CHECK(zenit_d11_commands_storage_snapshot_count(commands) ==
        (gpu_only ? 3u : 2u));
  CHECK(zenit_d12_render_pass_end(pass) == 0);
  if (evict_uniforms) zenit_d11_clear_uniform_cache(device);
  // Neither the mutable caller buffer nor its bind group/pipeline remain alive
  // when playback begins. The two immutable recorded versions must survive.
  memset(mapped, 0, 32);
  zenit_d12_bind_group_release(group);
  zenit_d12_buffer_release(storage);
  zenit_d12_buffer_release(upload);
  zenit_d12_render_pipeline_release(pipeline);
  zenit_d12_pipeline_layout_release(layout);
  zenit_d12_bind_group_release(compute_group);
  zenit_d12_compute_pipeline_release(compute_pipeline);
  zenit_d12_pipeline_layout_release(compute_layout);
  ZenitD12TextureRegion region = {0, 0, 0, 0, 0, 4, 4, 1};
  CHECK(zenit_d12_commands_texture_copy(commands, readback, 0, 256, texture,
                                        &region, 0) == 0);
  CHECK(zenit_d12_commands_finish(commands) == 0);
  uint64_t serial = 0;
  CHECK(zenit_d12_queue_submit(queue, commands, &serial) == 0);
  CHECK(zenit_d12_queue_wait(queue, serial, 30000) == 0);
  uint64_t untimed_elapsed = UINT64_MAX;
  CHECK(zenit_d12_commands_elapsed_micros(commands, &untimed_elapsed) == 1);
  CHECK(untimed_elapsed == 0);
  auto pixels = (const unsigned char *)zenit_d12_buffer_mapping(readback);
  CHECK(pixels);
  for (int y = 0; y < 4; ++y)
    for (int x = 0; x < 4; ++x) {
      const auto pixel = pixels + y * 256 + x * 4;
      CHECK(pixel[0] == (x == 2 ? 0 : 255) && pixel[1] == 0 &&
            pixel[2] == (x == 2 ? 255 : 0) && pixel[3] == 255);
    }
  zenit_d12_commands_release(commands);
  zenit_d12_texture_release(texture);
  zenit_d12_buffer_release(readback);
  return 0;
}
// Independent immediate-only query: excludes deferred playback from diagnosis.
static void diagnose_immediate_timestamp() {
  DiagnosticCom<ID3D11Device> device;
  DiagnosticCom<ID3D11DeviceContext> context;
  D3D_FEATURE_LEVEL level = D3D_FEATURE_LEVEL_11_0;
  HRESULT hr =
      D3D11CreateDevice(nullptr, D3D_DRIVER_TYPE_HARDWARE, nullptr, 0, &level,
                        1, D3D11_SDK_VERSION, &device.p, nullptr, &context.p);
  if (FAILED(hr)) {
    fprintf(stderr, "D3D11 immediate diagnostic create=0x%08lx\n",
            (unsigned long)hr);
    return;
  }
  DiagnosticCom<ID3D11Query> disjoint, start, end;
  D3D11_QUERY_DESC query = {D3D11_QUERY_TIMESTAMP_DISJOINT, 0};
  hr = device.p->CreateQuery(&query, &disjoint.p);
  query.Query = D3D11_QUERY_TIMESTAMP;
  if (SUCCEEDED(hr))
    hr = device.p->CreateQuery(&query, &start.p);
  if (SUCCEEDED(hr))
    hr = device.p->CreateQuery(&query, &end.p);
  DiagnosticCom<ID3D11Texture2D> texture;
  DiagnosticCom<ID3D11RenderTargetView> view;
  D3D11_TEXTURE2D_DESC desc = {};
  desc.Width = desc.Height = 4;
  desc.MipLevels = desc.ArraySize = desc.SampleDesc.Count = 1;
  desc.Format = DXGI_FORMAT_R8G8B8A8_UNORM;
  desc.Usage = D3D11_USAGE_DEFAULT;
  desc.BindFlags = D3D11_BIND_RENDER_TARGET;
  if (SUCCEEDED(hr))
    hr = device.p->CreateTexture2D(&desc, nullptr, &texture.p);
  if (SUCCEEDED(hr))
    hr = device.p->CreateRenderTargetView(texture.p, nullptr, &view.p);
  if (FAILED(hr)) {
    fprintf(stderr, "D3D11 immediate diagnostic setup=0x%08lx\n",
            (unsigned long)hr);
    return;
  }
  const float color[4] = {1, 0, 0, 1};
  context.p->Begin(disjoint.p);
  context.p->End(start.p);
  context.p->ClearRenderTargetView(view.p, color);
  context.p->End(end.p);
  context.p->End(disjoint.p);
  context.p->Flush();
  D3D11_QUERY_DATA_TIMESTAMP_DISJOINT result = {};
  for (int attempt = 0; attempt < 100; ++attempt) {
    hr = context.p->GetData(disjoint.p, &result, sizeof(result), 0);
    if (hr != S_FALSE)
      break;
    Sleep(10);
  }
  fprintf(stderr,
          "D3D11 immediate-only diagnostic: hr=0x%08lx frequency=%llu "
          "disjoint=%d\n",
          (unsigned long)hr, (unsigned long long)result.Frequency,
          result.Disjoint);
}
static int check_lcd_blend(ZenitD12Device *device, ZenitD12Queue *queue) {
  const char vertex[] = "float4 vs(uint id:SV_VertexID):SV_Position{float2 p=float2((id<<1)&2,id&2);return float4(p*float2(2,-2)+float2(-1,1),0,1);}";
  const char *fragments[] = {
    "struct O{float4 color:SV_Target0;float4 weights:SV_Target1;};O ps(){O o;o.color=float4(.05,.2,.45,.6);o.weights=float4(.2,.4,.6,.6);return o;}",
    "float4 ps():SV_Target0{return float4(.05,.2,.45,.6);}",
    "struct O{float4 color:SV_Target0;float3 weights:SV_Target1;};O ps(){O o;o.color=float4(.05,.2,.45,.6);o.weights=float3(.2,.4,.6);return o;}"
  };
  ZenitD12Shader *vs=nullptr; char *diagnostic=nullptr; size_t diagnostic_size=0;
  CHECK(zenit_d12_shader_compile(vertex,strlen(vertex),"vs",1,&vs,&diagnostic,&diagnostic_size)==0);
  zenit_d12_shader_diagnostic_free(diagnostic);
  ZenitD12PipelineLayout *layout=nullptr;
  CHECK(zenit_d12_pipeline_layout_create(device,0,nullptr,0,&layout)==0);
  ZenitD12ColorTarget target={};target.format=28;target.write_mask=15;target.blend=1;
  target.color_src=target.alpha_src=D3D11_BLEND_ONE;
  target.color_dst=D3D11_BLEND_INV_SRC1_COLOR;target.alpha_dst=D3D11_BLEND_INV_SRC1_ALPHA;
  target.color_op=target.alpha_op=D3D11_BLEND_OP_ADD;
  ZenitD12RenderDescriptor descriptor={};descriptor.targets=&target;descriptor.target_count=1;
  descriptor.topology=D3D11_PRIMITIVE_TOPOLOGY_TRIANGLELIST;descriptor.fill=D3D11_FILL_SOLID;
  descriptor.cull=D3D11_CULL_NONE;descriptor.depth_clip=1;descriptor.sample_mask=UINT32_MAX;descriptor.samples=1;
  ZenitD12RenderPipeline *pipeline=nullptr;
  for(int i=0;i<3;i++) {
    ZenitD12Shader *ps=nullptr;diagnostic=nullptr;
    CHECK(zenit_d12_shader_compile(fragments[i],strlen(fragments[i]),"ps",2,&ps,&diagnostic,&diagnostic_size)==0);
    zenit_d12_shader_diagnostic_free(diagnostic);
    ZenitD12RenderPipeline *candidate=nullptr;
    int status=zenit_d12_render_pipeline_create(device,layout,vs,ps,&descriptor,&candidate);
    CHECK(i==0 ? status==0 && candidate : status==1 && !candidate);
    if(i==0)pipeline=candidate;
    zenit_d12_shader_release(ps);
  }
  ZenitD12Texture *texture=nullptr;ZenitD12Buffer *readback=nullptr;ZenitD12Commands *commands=nullptr;
  CHECK(zenit_d12_texture_create(device,2,4,4,1,1,28,1|16,1,&texture)==0);
  CHECK(zenit_d12_buffer_create(device,1024,1|8,&readback)==0);
  CHECK(zenit_d12_commands_create(device,&commands)==0);
  ZenitD12ColorAttachment attachment={};attachment.texture=texture;attachment.load_op=1;
  attachment.clear[0]=.8f;attachment.clear[1]=.6f;attachment.clear[2]=.4f;attachment.clear[3]=1;
  ZenitD12RenderPass *pass=nullptr;
  CHECK(zenit_d12_render_pass_begin(commands,&attachment,1,nullptr,&pass)==0);
  ZenitD12Draw draw={};draw.vertices=3;draw.instances=1;draw.width=draw.height=4;
  CHECK(zenit_d12_render_pass_draw(pass,pipeline,&draw)==0);
  CHECK(zenit_d12_render_pass_end(pass)==0);
  ZenitD12TextureRegion region={};region.width=region.height=4;region.depth=1;
  CHECK(zenit_d12_commands_texture_copy(commands,readback,0,256,texture,&region,0)==0);
  CHECK(zenit_d12_commands_finish(commands)==0);uint64_t serial=0;
  CHECK(zenit_d12_queue_submit(queue,commands,&serial)==0);
  CHECK(zenit_d12_queue_wait(queue,serial,30000)==0);
  const auto *pixels=static_cast<const uint8_t *>(zenit_d12_buffer_mapping(readback));CHECK(pixels);
  for(int y=0;y<4;y++)for(int x=0;x<4;x++) {
    const auto *pixel=pixels+y*256+x*4;
    CHECK(pixel[0]==176 && pixel[1]==143 && pixel[2]==156 && pixel[3]==255);
  }
  zenit_d12_commands_release(commands);zenit_d12_buffer_release(readback);zenit_d12_texture_release(texture);
  zenit_d12_render_pipeline_release(pipeline);zenit_d12_pipeline_layout_release(layout);zenit_d12_shader_release(vs);
  puts("D3D11 LCD contract: arbitrary opaque RGB blend and invalid secondary signatures PASS");
  return 0;
}

extern "C" int zenit_d11_test_contract() {
  diagnose_immediate_timestamp();
  SetEnvironmentVariableA("ZENIT_D11_TIMESTAMP_TRACE", "1");
  ZenitD12Device *device = nullptr;
  CHECK(zenit_d12_device_create(0, &device) == 0);
  CHECK(!zenit_d12_device_is_software(
      device)); // This gate requires VMware hardware.
  ZenitD12Queue *queue = nullptr;
  CHECK(zenit_d12_queue_create(device, &queue) == 0);
  CHECK(check_storage_snapshots(device, queue, false) == 0);
  CHECK(check_storage_snapshots(device, queue, true) == 0);
  CHECK(check_storage_snapshots(device, queue, true, true) == 0);
  CHECK(check_storage_snapshots(device, queue, false, false, true) == 0);
  CHECK(zenit_d11_uniform_buffer_creations(device) == 2);
  CHECK(check_storage_snapshots(device, queue, false, false, true, true) == 0);
  CHECK(zenit_d11_uniform_buffer_creations(device) == 2);
  CHECK(check_lcd_blend(device, queue) == 0);
  puts("D3D11 cross-command uniform cache: no second-frame allocation, cache eviction preserves recorded pixels PASS");
  puts("D3D11 uniform snapshot contract: equal bytes across offsets reuse storage, overwrite/caller release pixels PASS");
  puts("D3D11 storage snapshot contract: mapped content reuse, GPU write "
       "version/copyback invalidation, caller release pixels PASS");
  puts("D3D11 untimed completion contract: failed sample, never permanently pending PASS");
  ZenitD12Texture *texture = nullptr;
  CHECK(zenit_d12_texture_create(device, 2, 4, 4, 1, 1, 28, 1 | 2 | 4 | 16, 1,
                                 &texture) == 0);
  ZenitD12Buffer *upload = nullptr, *readback = nullptr;
  CHECK(zenit_d12_buffer_create(device, 1024, 2 | 4, &upload) == 0);
  CHECK(zenit_d12_buffer_create(device, 1024, 1 | 8, &readback) == 0);
  auto bytes = (unsigned char *)zenit_d12_buffer_mapping(upload);
  CHECK(bytes);
  memset(bytes, 0, 1024);
  for (int y = 0; y < 4; y++)
    for (int x = 0; x < 4; x++) {
      bytes[y * 256 + x * 4] = 255;
      bytes[y * 256 + x * 4 + 3] = 255;
    }
  ZenitD12TextureRegion region = {0, 0, 0, 0, 0, 4, 4, 1};
  ZenitD12TextureLayout layout = {};
  CHECK(zenit_d12_texture_layout(texture, &region, 0, &layout) == 0);
  CHECK(layout.row_bytes == 16 && layout.row_pitch == 256 &&
        layout.required_bytes <= 1024);
  ZenitD12Commands *commands = nullptr;
  CHECK(zenit_d12_commands_create(device, &commands) == 0);
  CHECK(zenit_d12_commands_enable_timestamps(commands) == 0);
  CHECK(zenit_d12_commands_enable_timestamps(commands) == 1);
  uint64_t elapsed = 123;
  CHECK(zenit_d12_commands_elapsed_micros(commands, &elapsed) == 3);
  CHECK(elapsed == 0);
  CHECK(zenit_d12_commands_texture_copy(commands, upload, 0, 256, texture,
                                        &region, 1) == 0);
  // The recorded upload must own its bytes, even when the caller overwrites
  // storage.
  memset(bytes, 0, 1024);
  zenit_d12_buffer_release(upload);
  ZenitD12Buffer *patch = nullptr;
  CHECK(zenit_d12_buffer_create(device, 256, 2 | 4, &patch) == 0);
  auto patch_bytes = (unsigned char *)zenit_d12_buffer_mapping(patch);
  CHECK(patch_bytes);
  memset(patch_bytes, 0, 256);
  patch_bytes[2] = 255;
  patch_bytes[3] = 255;
  ZenitD12TextureRegion corner = {0, 0, 3, 0, 0, 1, 1, 1};
  CHECK(zenit_d12_commands_texture_copy(commands, patch, 0, 256, texture,
                                        &corner, 1) == 0);
  memset(patch_bytes, 0, 256);
  zenit_d12_buffer_release(patch);
  ZenitD12ColorAttachment attachment = {};
  attachment.texture = texture;
  attachment.load_op = 0;
  ZenitD12RenderPass *pass = nullptr;
  CHECK(zenit_d12_render_pass_begin(commands, &attachment, 1, nullptr, &pass) ==
        0);
  float green[4] = {0, 1, 0, 1};
  CHECK(zenit_d12_render_pass_clear_opaque(pass, green, 1, 1, 2, 2) == 0);
  CHECK(zenit_d12_render_pass_end(pass) == 0);
  CHECK(zenit_d12_commands_texture_copy(commands, readback, 0, 256, texture,
                                        &region, 0) == 0);
  CHECK(zenit_d12_commands_finish(commands) == 0);
  uint64_t serial = 0;
  CHECK(zenit_d12_queue_submit(queue, commands, &serial) == 0);
  CHECK(serial > 0);
  CHECK(zenit_d12_queue_wait(queue, serial, 30000) == 0);
  auto output = (const unsigned char *)zenit_d12_buffer_mapping(readback);
  CHECK(output);
  for (int y = 0; y < 4; y++)
    for (int x = 0; x < 4; x++) {
      bool center = x >= 1 && x < 3 && y >= 1 && y < 3;
      auto pixel = output + y * 256 + x * 4;
      bool blue = x == 3 && y == 0;
      CHECK(pixel[0] == (center || blue ? 0 : 255) &&
            pixel[1] == (center ? 255 : 0) && pixel[2] == (blue ? 255 : 0) &&
            pixel[3] == 255);
    }
  puts("D3D11 hardware contract: upload snapshot, nonzero-offset update, "
       "partial clear, padded readback, submit/wait PASS");
  puts("D3D11 storage snapshot contract: reuse, overwrite, caller-release "
       "lifetime PASS");
  int timing_status = zenit_d12_commands_elapsed_micros(commands, &elapsed);
  for (int attempt = 0;
       attempt < 16 && (timing_status == 3 || timing_status == 5); ++attempt) {
    zenit_d12_commands_release(commands);
    Sleep(10);
    CHECK(zenit_d12_commands_create(device, &commands) == 0);
    CHECK(zenit_d12_commands_enable_timestamps(commands) == 0);
    CHECK(zenit_d12_commands_texture_copy(commands, readback, 0, 256, texture,
                                          &region, 0) == 0);
    CHECK(zenit_d12_commands_finish(commands) == 0);
    CHECK(zenit_d12_queue_submit(queue, commands, &serial) == 0);
    CHECK(zenit_d12_queue_wait(queue, serial, 30000) == 0);
    timing_status = zenit_d12_commands_elapsed_micros(commands, &elapsed);
  }
  fprintf(stderr, "D3D11 GPU timing status=%d micros=%llu\n", timing_status,
          (unsigned long long)elapsed);
  CHECK(timing_status == 0);
  CHECK(elapsed > 0);
  const uint64_t completed_elapsed = elapsed;
  zenit_d12_buffer_release(readback);
  zenit_d12_texture_release(texture);
  CHECK(zenit_d12_queue_destroy(queue, 30000) == 0);
  CHECK(zenit_d12_commands_elapsed_micros(commands, &elapsed) == 0);
  CHECK(elapsed == completed_elapsed);
  zenit_d12_commands_release(commands);
  puts("D3D11 timestamp contract: pending, GPU duration, queue-independent "
       "lifetime PASS");
  zenit_d12_device_release(device);

  return 0;
}
