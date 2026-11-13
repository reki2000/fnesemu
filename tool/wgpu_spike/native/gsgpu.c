// A thin shim over wgpu-native for the compute GS. Dart calls these
// functions through dart:ffi; the shim owns the WebGPU objects.
//
// The GS local memory is a storage buffer of 4 MiB. gsgpu_run uploads the
// primitives, the data words and the parameters of a list of steps, and runs
// the steps in order in one compute pass. A step is a kind (an entry point of
// gs.wgsl) and a dispatch size; its parameters are 64 bytes at 256 bytes per
// step, bound with a dynamic offset.
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

#include "webgpu/webgpu.h"
#include "webgpu/wgpu.h"

#define VRAM_BYTES (4u * 1024u * 1024u)
#define PRIM_BYTES (262144u * 28u * 4u)
#define SETUP_BYTES (262144u * 12u * 4u)
#define DATA_BYTES (64u * 1024u * 1024u)
#define CLUT_BYTES (2048u * 512u * 4u)
#define MAX_STEPS 65536u
#define STEP_STRIDE 256u
#define KINDS 6

static WGPUInstance instance;
static WGPUAdapter adapter;
static WGPUDevice device;
static WGPUQueue queue;
static WGPUBuffer vram, snap, prims, setups, data, cluts, params, readback;
static WGPUComputePipeline pipes[KINDS];
static WGPUBindGroup group;
static char lastError[1024];

// GSGPU_PROFILE: timestamps around the first PROFILE_STEPS dispatches
#define PROFILE_STEPS 2048u
static int profile;
static WGPUQuerySet queries;
static WGPUBuffer resolved, profileRead;

static double now_ms(void) {
  struct timespec t;
  clock_gettime(CLOCK_MONOTONIC, &t);
  return t.tv_sec * 1e3 + t.tv_nsec / 1e6;
}

static WGPUStringView sv(const char *s) {
  WGPUStringView v = {s, strlen(s)};
  return v;
}

static void on_device_error(WGPUDevice const *d, WGPUErrorType type,
                            WGPUStringView message, void *u1, void *u2) {
  (void)d, (void)u1, (void)u2;
  snprintf(lastError, sizeof lastError, "device error %d: %.*s", (int)type,
           (int)message.length, message.data);
  fprintf(stderr, "%s\n", lastError);
}

static void on_device(WGPURequestDeviceStatus status, WGPUDevice d,
                      WGPUStringView message, void *u1, void *u2) {
  (void)u2;
  if (status == WGPURequestDeviceStatus_Success) {
    *(WGPUDevice *)u1 = d;
  } else {
    snprintf(lastError, sizeof lastError, "request device: %.*s",
             (int)message.length, message.data);
  }
}

static WGPUBuffer buffer(uint64_t size, WGPUBufferUsage usage) {
  WGPUBufferDescriptor d = WGPU_BUFFER_DESCRIPTOR_INIT;
  d.size = size;
  d.usage = usage;
  return wgpuDeviceCreateBuffer(device, &d);
}

const char *gsgpu_error(void) { return lastError; }

// Opens the first adapter whose description contains [name] on [backends]
// (a WGPUInstanceBackend mask, 0 for all), compiles [wgsl], and writes the
// adapter list to [info]. Returns 0 on success.
int gsgpu_init(const char *name, uint32_t backends, const char *wgsl,
               char *info, int infoLength) {
  WGPUInstanceExtras extras = {0};
  extras.chain.sType = (WGPUSType)WGPUSType_InstanceExtras;
  extras.backends = backends;
  // dozen (Vulkan over D3D12 in WSL) reports conformance version 0
  extras.flags = WGPUInstanceFlag_AllowUnderlyingNoncompliantAdapter |
                 WGPUInstanceFlag_AutomaticTimestampNormalization;
  WGPUInstanceDescriptor id = WGPU_INSTANCE_DESCRIPTOR_INIT;
  id.nextInChain = &extras.chain;
  instance = wgpuCreateInstance(&id);
  if (!instance) {
    snprintf(lastError, sizeof lastError, "no instance");
    return 1;
  }
  WGPUInstanceEnumerateAdapterOptions eo = {0};
  eo.backends = backends;
  size_t count = wgpuInstanceEnumerateAdapters(instance, &eo, NULL);
  WGPUAdapter *list = calloc(count ? count : 1, sizeof *list);
  wgpuInstanceEnumerateAdapters(instance, &eo, list);
  int used = 0;
  info[0] = 0;
  for (size_t i = 0; i < count; i++) {
    WGPUAdapterInfo ai = WGPU_ADAPTER_INFO_INIT;
    wgpuAdapterGetInfo(list[i], &ai);
    char line[512];
    snprintf(line, sizeof line, "%.*s (backend %d, type %d)",
             (int)ai.device.length, ai.device.data, (int)ai.backendType,
             (int)ai.adapterType);
    int match = !adapter && strstr(line, name) != NULL;
    used += snprintf(info + used, infoLength - used, "%s%s\n",
                     match ? "* " : "  ", line);
    if (used >= infoLength) used = infoLength - 1;
    if (match) adapter = list[i];
    wgpuAdapterInfoFreeMembers(ai);
  }
  free(list);
  if (!adapter) {
    snprintf(lastError, sizeof lastError, "no adapter matches '%s'", name);
    return 2;
  }
  WGPULimits limits = WGPU_LIMITS_INIT;
  wgpuAdapterGetLimits(adapter, &limits);
  WGPUDeviceDescriptor dd = WGPU_DEVICE_DESCRIPTOR_INIT;
  dd.requiredLimits = &limits;
  WGPUFeatureName features[2] = {
      WGPUFeatureName_TimestampQuery,
      (WGPUFeatureName)WGPUNativeFeature_TimestampQueryInsidePasses};
  profile = getenv("GSGPU_PROFILE") != NULL &&
            wgpuAdapterHasFeature(adapter, features[1]);
  if (profile) {
    dd.requiredFeatureCount = 2;
    dd.requiredFeatures = features;
  }
  dd.uncapturedErrorCallbackInfo.callback = on_device_error;
  WGPURequestDeviceCallbackInfo cb = WGPU_REQUEST_DEVICE_CALLBACK_INFO_INIT;
  cb.mode = WGPUCallbackMode_AllowProcessEvents;
  cb.callback = on_device;
  cb.userdata1 = &device;
  wgpuAdapterRequestDevice(adapter, &dd, cb);
  for (int i = 0; i < 1000 && !device && !lastError[0]; i++) {
    wgpuInstanceProcessEvents(instance);
  }
  if (!device) return 3;
  queue = wgpuDeviceGetQueue(device);

  const WGPUBufferUsage storage = WGPUBufferUsage_Storage |
                                  WGPUBufferUsage_CopyDst |
                                  WGPUBufferUsage_CopySrc;
  vram = buffer(VRAM_BYTES, storage);
  snap = buffer(VRAM_BYTES, storage);
  prims = buffer(PRIM_BYTES, storage);
  setups = buffer(SETUP_BYTES, storage);
  data = buffer(DATA_BYTES, storage);
  cluts = buffer(CLUT_BYTES, storage);
  params = buffer(MAX_STEPS * STEP_STRIDE,
                  WGPUBufferUsage_Uniform | WGPUBufferUsage_CopyDst);
  readback = buffer(VRAM_BYTES,
                    WGPUBufferUsage_MapRead | WGPUBufferUsage_CopyDst);

  WGPUShaderSourceWGSL src = WGPU_SHADER_SOURCE_WGSL_INIT;
  src.code = sv(wgsl);
  WGPUShaderModuleDescriptor sd = WGPU_SHADER_MODULE_DESCRIPTOR_INIT;
  sd.nextInChain = &src.chain;
  WGPUShaderModule module = wgpuDeviceCreateShaderModule(device, &sd);

  WGPUBufferBindingType types[7] = {
      WGPUBufferBindingType_Storage, WGPUBufferBindingType_Storage,
      WGPUBufferBindingType_ReadOnlyStorage, WGPUBufferBindingType_Storage,
      WGPUBufferBindingType_ReadOnlyStorage, WGPUBufferBindingType_Storage,
      WGPUBufferBindingType_Uniform};
  WGPUBindGroupLayoutEntry e[7];
  for (int i = 0; i < 7; i++) {
    WGPUBindGroupLayoutEntry z = WGPU_BIND_GROUP_LAYOUT_ENTRY_INIT;
    z.binding = i;
    z.visibility = WGPUShaderStage_Compute;
    z.buffer.type = types[i];
    e[i] = z;
  }
  e[6].buffer.hasDynamicOffset = 1;
  e[6].buffer.minBindingSize = 64;
  WGPUBindGroupLayoutDescriptor ld = WGPU_BIND_GROUP_LAYOUT_DESCRIPTOR_INIT;
  ld.entryCount = 7;
  ld.entries = e;
  WGPUBindGroupLayout layout = wgpuDeviceCreateBindGroupLayout(device, &ld);
  WGPUPipelineLayoutDescriptor pd = WGPU_PIPELINE_LAYOUT_DESCRIPTOR_INIT;
  pd.bindGroupLayoutCount = 1;
  pd.bindGroupLayouts = &layout;
  WGPUPipelineLayout pipelineLayout =
      wgpuDeviceCreatePipelineLayout(device, &pd);

  const char *entries[KINDS] = {"setup", "raster", "clut",
                                "upload", "copy", "snapshot"};
  for (int i = 0; i < KINDS; i++) {
    WGPUComputePipelineDescriptor cd = WGPU_COMPUTE_PIPELINE_DESCRIPTOR_INIT;
    cd.layout = pipelineLayout;
    cd.compute.module = module;
    cd.compute.entryPoint = sv(entries[i]);
    pipes[i] = wgpuDeviceCreateComputePipeline(device, &cd);
  }

  WGPUBuffer bound[7] = {vram, snap, prims, setups, data, cluts, params};
  uint64_t sizes[7] = {VRAM_BYTES, VRAM_BYTES, PRIM_BYTES, SETUP_BYTES,
                       DATA_BYTES, CLUT_BYTES, 64};
  WGPUBindGroupEntry ge[7];
  for (int i = 0; i < 7; i++) {
    WGPUBindGroupEntry z = WGPU_BIND_GROUP_ENTRY_INIT;
    z.binding = i;
    z.buffer = bound[i];
    z.size = sizes[i];
    ge[i] = z;
  }
  WGPUBindGroupDescriptor gd = WGPU_BIND_GROUP_DESCRIPTOR_INIT;
  gd.layout = layout;
  gd.entryCount = 7;
  gd.entries = ge;
  group = wgpuDeviceCreateBindGroup(device, &gd);
  if (profile) {
    WGPUQuerySetDescriptor qd = WGPU_QUERY_SET_DESCRIPTOR_INIT;
    qd.type = WGPUQueryType_Timestamp;
    qd.count = PROFILE_STEPS * 2;
    queries = wgpuDeviceCreateQuerySet(device, &qd);
    resolved = buffer(PROFILE_STEPS * 16,
                      WGPUBufferUsage_QueryResolve | WGPUBufferUsage_CopySrc);
    profileRead = buffer(PROFILE_STEPS * 16,
                         WGPUBufferUsage_MapRead | WGPUBufferUsage_CopyDst);
  }
  wgpuDevicePoll(device, 1, NULL);
  return lastError[0] ? 4 : 0;
}

// Writes [count] words at word [offset] of the local memory.
void gsgpu_write_vram(const uint32_t *words, uint32_t offset, uint32_t count) {
  wgpuQueueWriteBuffer(queue, vram, offset * 4ull, words, count * 4ull);
}

// Writes the 512 entries of CLUT version [version].
void gsgpu_write_clut(uint32_t version, const uint32_t *words) {
  wgpuQueueWriteBuffer(queue, cluts, version * 2048ull, words, 2048);
}

static void on_mapped(WGPUMapAsyncStatus status, WGPUStringView message,
                      void *u1, void *u2) {
  (void)u2;
  if (status != WGPUMapAsyncStatus_Success) {
    snprintf(lastError, sizeof lastError, "map: %.*s", (int)message.length,
             message.data);
  }
  *(int *)u1 = 1;
}

static void on_mapped_profile(WGPUMapAsyncStatus status, WGPUStringView m,
                              void *u1, void *u2) {
  (void)status, (void)m, (void)u2;
  *(int *)u1 = 1;
}

// Runs [count] steps of 4 words (kind and dispatch size x, y, z) with 64
// words of parameters per step, after uploading [primWords] words of
// primitives and [dataWords] data words. [times] receives the milliseconds to
// upload, to encode and submit, and to wait for the GPU. Without [wait], the
// run is only submitted: the buffers are written in queue order, so the next
// run may reuse them at once.
int gsgpu_run(const uint32_t *steps, uint32_t count, const uint32_t *stepParams,
              const uint32_t *primWords, uint32_t primCount,
              const uint32_t *dataWords, uint32_t dataCount, uint32_t wait,
              double *times) {
  if (count > MAX_STEPS || primCount * 4ull > PRIM_BYTES ||
      dataCount * 4ull > DATA_BYTES) {
    snprintf(lastError, sizeof lastError, "run too large");
    return 1;
  }
  double t0 = now_ms();
  if (primCount) wgpuQueueWriteBuffer(queue, prims, 0, primWords, primCount * 4ull);
  if (dataCount) wgpuQueueWriteBuffer(queue, data, 0, dataWords, dataCount * 4ull);
  if (count) wgpuQueueWriteBuffer(queue, params, 0, stepParams, count * STEP_STRIDE);
  double t1 = now_ms();
  WGPUCommandEncoder enc = wgpuDeviceCreateCommandEncoder(device, NULL);
  WGPUComputePassEncoder pass = wgpuCommandEncoderBeginComputePass(enc, NULL);
  int last = -1;
  // GSGPU_SKIP lists step kinds (digits) to leave out, to time the others
  const char *skip = getenv("GSGPU_SKIP");
  for (uint32_t k = 0; k < count; k++) {
    const uint32_t *s = steps + k * 4;
    if (s[0] >= KINDS || !s[1] || !s[2] || !s[3]) continue;
    if (skip && strchr(skip, '0' + (int)s[0])) continue;
    if ((int)s[0] != last) {
      wgpuComputePassEncoderSetPipeline(pass, pipes[s[0]]);
      last = s[0];
    }
    uint32_t offset = k * STEP_STRIDE;
    wgpuComputePassEncoderSetBindGroup(pass, 0, group, 1, &offset);
    if (profile && k < PROFILE_STEPS) {
      wgpuComputePassEncoderWriteTimestamp(pass, queries, k * 2);
    }
    wgpuComputePassEncoderDispatchWorkgroups(pass, s[1], s[2], s[3]);
    if (profile && k < PROFILE_STEPS) {
      wgpuComputePassEncoderWriteTimestamp(pass, queries, k * 2 + 1);
    }
  }
  wgpuComputePassEncoderEnd(pass);
  uint32_t timed = count < PROFILE_STEPS ? count : PROFILE_STEPS;
  if (profile && timed) {
    wgpuCommandEncoderResolveQuerySet(enc, queries, 0, timed * 2, resolved, 0);
    wgpuCommandEncoderCopyBufferToBuffer(enc, resolved, 0, profileRead, 0,
                                         timed * 16ull);
  }
  WGPUCommandBuffer cmd = wgpuCommandEncoderFinish(enc, NULL);
  wgpuQueueSubmit(queue, 1, &cmd);
  wgpuCommandBufferRelease(cmd);
  wgpuComputePassEncoderRelease(pass);
  wgpuCommandEncoderRelease(enc);
  double t2 = now_ms();
  wgpuDevicePoll(device, wait || profile, NULL);
  double t3 = now_ms();
  if (profile && timed) {
    int done = 0;
    WGPUBufferMapCallbackInfo pc = WGPU_BUFFER_MAP_CALLBACK_INFO_INIT;
    pc.mode = WGPUCallbackMode_AllowProcessEvents;
    pc.callback = on_mapped_profile;
    pc.userdata1 = &done;
    wgpuBufferMapAsync(profileRead, WGPUMapMode_Read, 0, timed * 16ull, pc);
    while (!done) {
      wgpuDevicePoll(device, 1, NULL);
      wgpuInstanceProcessEvents(instance);
    }
    const uint64_t *ts =
        wgpuBufferGetConstMappedRange(profileRead, 0, timed * 16ull);
    static const char *names[KINDS] = {"setup", "raster", "clut",
                                       "upload", "copy", "snapshot"};
    uint32_t ranked[10] = {0};
    double sum[KINDS] = {0}, top = 0;
    uint32_t n[KINDS] = {0}, topStep = 0;
    for (uint32_t k = 0; k < timed; k++) {
      uint32_t kind = steps[k * 4];
      if (kind >= KINDS || !steps[k * 4 + 1]) continue;
      double ms = (ts[k * 2 + 1] - ts[k * 2]) / 1e6;
      sum[kind] += ms;
      n[kind]++;
      if (ms > top) top = ms, topStep = k;
    }
    double span = (ts[(timed - 1) * 2 + 1] - ts[0]) / 1e6;
    fprintf(stderr, "profile: span %.2f ms;", span);
    for (int i = 0; i < KINDS; i++) {
      if (n[i]) fprintf(stderr, " %s %u %.2f ms;", names[i], n[i], sum[i]);
    }
    fprintf(stderr, " longest step %u (%s %ux%u) %.2f ms\n", topStep,
            names[steps[topStep * 4]], steps[topStep * 4 + 1],
            steps[topStep * 4 + 2], top);
    // the ten longest steps: kind, tiles, primitives (raster), ms
    for (int r = 0; r < 10; r++) {
      double best = -1;
      uint32_t at = 0;
      for (uint32_t k = 0; k < timed; k++) {
        if (steps[k * 4] >= KINDS || !steps[k * 4 + 1]) continue;
        double ms = (ts[k * 2 + 1] - ts[k * 2]) / 1e6;
        int seen = 0;
        for (int q = 0; q < r; q++) seen |= ranked[q] == k;
        if (!seen && ms > best) best = ms, at = k;
      }
      ranked[r] = at;
      fprintf(stderr, "  step %u %s %ux%u prims %u: %.2f ms\n", at,
              names[steps[at * 4]], steps[at * 4 + 1], steps[at * 4 + 2],
              stepParams[at * 64 + 1], best);
    }
    wgpuBufferUnmap(profileRead);
  }
  times[0] = t1 - t0;
  times[1] = t2 - t1;
  times[2] = t3 - t2;
  return lastError[0] ? 2 : 0;
}

// Copies the whole local memory into [words].
int gsgpu_read_vram(uint32_t *words) {
  WGPUCommandEncoder enc = wgpuDeviceCreateCommandEncoder(device, NULL);
  wgpuCommandEncoderCopyBufferToBuffer(enc, vram, 0, readback, 0, VRAM_BYTES);
  WGPUCommandBuffer cmd = wgpuCommandEncoderFinish(enc, NULL);
  wgpuQueueSubmit(queue, 1, &cmd);
  wgpuCommandBufferRelease(cmd);
  wgpuCommandEncoderRelease(enc);
  int done = 0;
  WGPUBufferMapCallbackInfo cb = WGPU_BUFFER_MAP_CALLBACK_INFO_INIT;
  cb.mode = WGPUCallbackMode_AllowProcessEvents;
  cb.callback = on_mapped;
  cb.userdata1 = &done;
  wgpuBufferMapAsync(readback, WGPUMapMode_Read, 0, VRAM_BYTES, cb);
  while (!done) {
    wgpuDevicePoll(device, 1, NULL);
    wgpuInstanceProcessEvents(instance);
  }
  if (lastError[0]) return 1;
  memcpy(words, wgpuBufferGetConstMappedRange(readback, 0, VRAM_BYTES),
         VRAM_BYTES);
  wgpuBufferUnmap(readback);
  return 0;
}
