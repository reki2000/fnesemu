// Compute programs on wgpu-native for dart:ffi. The shim owns the WebGPU
// objects: a device, and programs of one WGSL module with several entry
// points that share one bind group of buffers.
//
// One binding of a program may hold parameters: a uniform buffer that holds
// a block of [paramStride] bytes per dispatch of a run, bound with a dynamic
// offset, so that each dispatch sees its own block.
#if defined(_WIN32)
#define _CRT_SECURE_NO_WARNINGS
#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#endif
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#if !defined(_WIN32)
#include <pthread.h>
#endif

#include "webgpu/webgpu.h"
#include "webgpu/wgpu.h"

#if defined(_WIN32)
#define EXPORT __declspec(dllexport)
#define strdup _strdup
#else
#define EXPORT __attribute__((visibility("default")))
#endif

#define MPC_STORAGE 0
#define MPC_READ_ONLY 1
#define MPC_PARAMS 2
#define MPC_MAX_BINDINGS 16
#define MPC_MAX_ENTRIES 32
// timestamps around the first dispatches of a run with MPC_PROFILE set
#define PROFILE_DISPATCHES 2048u

typedef struct MpcDevice {
  WGPUInstance instance;
  WGPUAdapter adapter;
  WGPUDevice device;
  WGPUQueue queue;
  int profile;
  char error[1024];
} MpcDevice;

typedef struct MpcProgram {
  MpcDevice *d;
  uint32_t entryCount, bindingCount, paramBinding, paramStride, maxDispatches;
  char *names[MPC_MAX_ENTRIES];
  WGPUComputePipeline pipes[MPC_MAX_ENTRIES];
  WGPUBuffer buffers[MPC_MAX_BINDINGS];
  uint64_t sizes[MPC_MAX_BINDINGS];
  WGPUBindGroup group;
  WGPUBuffer readback;
  uint64_t readbackSize;
  WGPUQuerySet queries;
  WGPUBuffer resolved, profileRead;
} MpcProgram;

// The allocator of the shim, for the arguments that Dart passes. The C
// library has different names on each OS, so Dart does not look it up.
EXPORT void *mpc_malloc(uint64_t bytes) { return malloc((size_t)bytes); }

EXPORT void mpc_free(void *pointer) { free(pointer); }

static WGPUStringView sv(const char *s) {
  WGPUStringView v = {s, strlen(s)};
  return v;
}

static void on_device_error(WGPUDevice const *device, WGPUErrorType type,
                            WGPUStringView message, void *u1, void *u2) {
  (void)device, (void)u2;
  MpcDevice *d = u1;
  snprintf(d->error, sizeof d->error, "device error %d: %.*s", (int)type,
           (int)message.length, message.data);
}

static void on_device(WGPURequestDeviceStatus status, WGPUDevice device,
                      WGPUStringView message, void *u1, void *u2) {
  (void)u2;
  MpcDevice *d = u1;
  if (status == WGPURequestDeviceStatus_Success) {
    d->device = device;
  } else {
    snprintf(d->error, sizeof d->error, "request device: %.*s",
             (int)message.length, message.data);
  }
}

static void on_mapped(WGPUMapAsyncStatus status, WGPUStringView message,
                      void *u1, void *u2) {
  MpcDevice *d = u2;
  if (status != WGPUMapAsyncStatus_Success) {
    snprintf(d->error, sizeof d->error, "map: %.*s", (int)message.length,
             message.data);
  }
  *(int *)u1 = 1;
}

static WGPUBuffer buffer(MpcDevice *d, uint64_t size, WGPUBufferUsage usage) {
  WGPUBufferDescriptor bd = WGPU_BUFFER_DESCRIPTOR_INIT;
  bd.size = size;
  bd.usage = usage;
  return wgpuDeviceCreateBuffer(d->device, &bd);
}

// Maps [b] for reading [size] bytes and waits for it.
static int map_read(MpcDevice *d, WGPUBuffer b, uint64_t size) {
  int done = 0;
  WGPUBufferMapCallbackInfo cb = WGPU_BUFFER_MAP_CALLBACK_INFO_INIT;
  cb.mode = WGPUCallbackMode_AllowProcessEvents;
  cb.callback = on_mapped;
  cb.userdata1 = &done;
  cb.userdata2 = d;
  wgpuBufferMapAsync(b, WGPUMapMode_Read, 0, size, cb);
  while (!done) {
    wgpuDevicePoll(d->device, 1, NULL);
    wgpuInstanceProcessEvents(d->instance);
  }
  return d->error[0] ? 1 : 0;
}

EXPORT const char *mpc_error(MpcDevice *d) { return d->error; }

static const char *backend_name(WGPUBackendType t) {
  switch (t) {
    case WGPUBackendType_D3D11: return "Direct3D 11";
    case WGPUBackendType_D3D12: return "Direct3D 12";
    case WGPUBackendType_Metal: return "Metal";
    case WGPUBackendType_Vulkan: return "Vulkan";
    case WGPUBackendType_OpenGL: return "OpenGL";
    case WGPUBackendType_OpenGLES: return "OpenGL ES";
    default: return "other backend";
  }
}

static const char *adapter_type_name(WGPUAdapterType t) {
  switch (t) {
    case WGPUAdapterType_DiscreteGPU: return "discrete";
    case WGPUAdapterType_IntegratedGPU: return "integrated";
    case WGPUAdapterType_CPU: return "CPU";
    default: return "unknown type";
  }
}

// An instance on [backends] (a WGPUInstanceBackend mask, 0 for all).
static WGPUInstance new_instance(uint32_t backends) {
  WGPUInstanceExtras extras = {0};
  extras.chain.sType = (WGPUSType)WGPUSType_InstanceExtras;
  extras.backends = backends;
  // dozen (Vulkan over D3D12 in WSL) reports conformance version 0
  extras.flags = WGPUInstanceFlag_AllowUnderlyingNoncompliantAdapter |
                 WGPUInstanceFlag_AutomaticTimestampNormalization;
  WGPUInstanceDescriptor id = WGPU_INSTANCE_DESCRIPTOR_INIT;
  id.nextInChain = &extras.chain;
  return wgpuCreateInstance(&id);
}

#if defined(_WIN32)
static SRWLOCK instance_lock = SRWLOCK_INIT;
#define LOCK_INSTANCES() AcquireSRWLockExclusive(&instance_lock)
#define UNLOCK_INSTANCES() ReleaseSRWLockExclusive(&instance_lock)
#else
static pthread_mutex_t instance_lock = PTHREAD_MUTEX_INITIALIZER;
#define LOCK_INSTANCES() pthread_mutex_lock(&instance_lock)
#define UNLOCK_INSTANCES() pthread_mutex_unlock(&instance_lock)
#endif

// The instance of the process on [backends]. It is never released: releasing
// it lets the Vulkan loader unload drivers whose threads still run, and the
// process crashes later. Null after 8 different masks.
static WGPUInstance create_instance(uint32_t backends) {
  static struct {
    uint32_t backends;
    WGPUInstance instance;
  } instances[8];
  WGPUInstance found = NULL;
  LOCK_INSTANCES();
  size_t i = 0;
  for (; i < 8 && instances[i].instance; i++) {
    if (instances[i].backends == backends) break;
  }
  if (i < 8) {
    if (!instances[i].instance) {
      instances[i].backends = backends;
      instances[i].instance = new_instance(backends);
    }
    found = instances[i].instance;
  }
  UNLOCK_INSTANCES();
  return found;
}

// The adapters of [instance] on [backends] in [*list], which the caller
// releases and frees. Returns their count.
static size_t enumerate(WGPUInstance instance, uint32_t backends,
                        WGPUAdapter **list) {
  WGPUInstanceEnumerateAdapterOptions eo = {0};
  eo.backends = backends;
  size_t count = wgpuInstanceEnumerateAdapters(instance, &eo, NULL);
  *list = calloc(count ? count : 1, sizeof **list);
  if (!*list) return 0;
  return wgpuInstanceEnumerateAdapters(instance, &eo, *list);
}

// Writes the description of [adapter], such as "name (Vulkan, discrete)",
// to [line], and returns its type.
static WGPUAdapterType describe(WGPUAdapter adapter, char *line, size_t n) {
  WGPUAdapterInfo ai = WGPU_ADAPTER_INFO_INIT;
  wgpuAdapterGetInfo(adapter, &ai);
  snprintf(line, n, "%.*s (%s, %s)", (int)ai.device.length, ai.device.data,
           backend_name(ai.backendType), adapter_type_name(ai.adapterType));
  WGPUAdapterType type = ai.adapterType;
  wgpuAdapterInfoFreeMembers(ai);
  return type;
}

// Writes the descriptions of the adapters on [backends] to [info], one per
// line, without opening a device. Returns their count.
EXPORT int32_t mpc_adapters(uint32_t backends, char *info,
                            int32_t infoLength) {
  info[0] = 0;
  WGPUInstance instance = create_instance(backends);
  if (!instance) return 0;
  WGPUAdapter *list;
  size_t count = enumerate(instance, backends, &list);
  int used = 0;
  for (size_t i = 0; i < count; i++) {
    char line[512];
    describe(list[i], line, sizeof line);
    if (used < infoLength) {
      used += snprintf(info + used, infoLength - used, "%s\n", line);
    }
    wgpuAdapterRelease(list[i]);
  }
  free(list);
  return (int32_t)count;
}

// Opens the first adapter whose description contains [name] on [backends]
// (a WGPUInstanceBackend mask, 0 for all), or the first discrete GPU (else
// the first adapter) when [name] is empty, and writes the list of adapters to
// [info], the chosen one marked with '*'. Returns a device, which reports
// any failure through mpc_error, or null when memory runs out.
EXPORT MpcDevice *mpc_device_open(const char *name, uint32_t backends,
                                  char *info, int32_t infoLength) {
  MpcDevice *d = calloc(1, sizeof *d);
  if (!d) return NULL;
  info[0] = 0;
  d->instance = create_instance(backends);
  if (!d->instance) {
    snprintf(d->error, sizeof d->error, "no instance");
    return d;
  }
  WGPUAdapter *list;
  size_t count = enumerate(d->instance, backends, &list);
  // without a name, a discrete GPU is preferred to the first adapter
  size_t chosen = SIZE_MAX;
  char line[512];
  for (size_t i = 0; i < count && !name[0]; i++) {
    if (chosen == SIZE_MAX &&
        describe(list[i], line, sizeof line) == WGPUAdapterType_DiscreteGPU) {
      chosen = i;
    }
  }
  if (!name[0] && chosen == SIZE_MAX && count) chosen = 0;
  int used = 0;
  for (size_t i = 0; i < count; i++) {
    describe(list[i], line, sizeof line);
    int match = !d->adapter &&
                (name[0] ? strstr(line, name) != NULL : i == chosen);
    if (used < infoLength) {
      used += snprintf(info + used, infoLength - used, "%s%s\n",
                       match ? "* " : "  ", line);
    }
    if (match) {
      d->adapter = list[i];
    } else {
      wgpuAdapterRelease(list[i]);
    }
  }
  free(list);
  if (!d->adapter) {
    snprintf(d->error, sizeof d->error, "no adapter matches '%s'", name);
    return d;
  }
  WGPULimits limits = WGPU_LIMITS_INIT;
  wgpuAdapterGetLimits(d->adapter, &limits);
  WGPUDeviceDescriptor dd = WGPU_DEVICE_DESCRIPTOR_INIT;
  dd.requiredLimits = &limits;
  WGPUFeatureName features[2] = {
      WGPUFeatureName_TimestampQuery,
      (WGPUFeatureName)WGPUNativeFeature_TimestampQueryInsidePasses};
  d->profile = getenv("MPC_PROFILE") != NULL &&
               wgpuAdapterHasFeature(d->adapter, features[0]) &&
               wgpuAdapterHasFeature(d->adapter, features[1]);
  if (d->profile) {
    dd.requiredFeatureCount = 2;
    dd.requiredFeatures = features;
  }
  dd.uncapturedErrorCallbackInfo.callback = on_device_error;
  dd.uncapturedErrorCallbackInfo.userdata1 = d;
  WGPURequestDeviceCallbackInfo cb = WGPU_REQUEST_DEVICE_CALLBACK_INFO_INIT;
  cb.mode = WGPUCallbackMode_AllowProcessEvents;
  cb.callback = on_device;
  cb.userdata1 = d;
  wgpuAdapterRequestDevice(d->adapter, &dd, cb);
  for (int i = 0; i < 1000 && !d->device && !d->error[0]; i++) {
    wgpuInstanceProcessEvents(d->instance);
  }
  if (!d->device) {
    if (!d->error[0]) snprintf(d->error, sizeof d->error, "no device");
    return d;
  }
  d->queue = wgpuDeviceGetQueue(d->device);
  return d;
}

// Creates a program of the [entryCount] entry points [entries] of [wgsl],
// with [bindingCount] buffers of [sizes] bytes at bindings 0, 1, ... of group
// 0, of the MPC_* [kinds]. A MPC_PARAMS binding is a block of [paramStride]
// bytes per dispatch for up to [maxDispatches] dispatches; its size is the
// block size the shader sees. Returns null and sets the error of [d] on
// failure.
EXPORT MpcProgram *mpc_program_create(MpcDevice *d, const char *wgsl,
                                      const char *const *entries,
                                      uint32_t entryCount,
                                      const uint32_t *kinds,
                                      const uint64_t *sizes,
                                      uint32_t bindingCount,
                                      uint32_t paramStride,
                                      uint32_t maxDispatches) {
  if (!d->device || entryCount > MPC_MAX_ENTRIES ||
      bindingCount > MPC_MAX_BINDINGS) {
    if (!d->error[0]) snprintf(d->error, sizeof d->error, "bad program");
    return NULL;
  }
  MpcProgram *p = calloc(1, sizeof *p);
  if (!p) return NULL;
  p->d = d;
  p->entryCount = entryCount;
  p->bindingCount = bindingCount;
  p->paramBinding = UINT32_MAX;
  p->paramStride = paramStride;
  p->maxDispatches = maxDispatches;

  WGPUShaderSourceWGSL src = WGPU_SHADER_SOURCE_WGSL_INIT;
  src.code = sv(wgsl);
  WGPUShaderModuleDescriptor sd = WGPU_SHADER_MODULE_DESCRIPTOR_INIT;
  sd.nextInChain = &src.chain;
  WGPUShaderModule module = wgpuDeviceCreateShaderModule(d->device, &sd);

  WGPUBindGroupLayoutEntry le[MPC_MAX_BINDINGS];
  WGPUBindGroupEntry ge[MPC_MAX_BINDINGS];
  const WGPUBufferUsage storage = WGPUBufferUsage_Storage |
                                  WGPUBufferUsage_CopyDst |
                                  WGPUBufferUsage_CopySrc;
  for (uint32_t i = 0; i < bindingCount; i++) {
    WGPUBindGroupLayoutEntry l = WGPU_BIND_GROUP_LAYOUT_ENTRY_INIT;
    l.binding = i;
    l.visibility = WGPUShaderStage_Compute;
    WGPUBindGroupEntry g = WGPU_BIND_GROUP_ENTRY_INIT;
    g.binding = i;
    if (kinds[i] == MPC_PARAMS) {
      p->paramBinding = i;
      l.buffer.type = WGPUBufferBindingType_Uniform;
      l.buffer.hasDynamicOffset = 1;
      l.buffer.minBindingSize = sizes[i];
      p->sizes[i] = (uint64_t)paramStride * maxDispatches;
      p->buffers[i] = buffer(d, p->sizes[i],
                             WGPUBufferUsage_Uniform | WGPUBufferUsage_CopyDst);
      g.size = sizes[i];
    } else {
      l.buffer.type = kinds[i] == MPC_READ_ONLY
                          ? WGPUBufferBindingType_ReadOnlyStorage
                          : WGPUBufferBindingType_Storage;
      p->sizes[i] = sizes[i];
      p->buffers[i] = buffer(d, sizes[i], storage);
      g.size = sizes[i];
    }
    g.buffer = p->buffers[i];
    le[i] = l;
    ge[i] = g;
  }
  WGPUBindGroupLayoutDescriptor ld = WGPU_BIND_GROUP_LAYOUT_DESCRIPTOR_INIT;
  ld.entryCount = bindingCount;
  ld.entries = le;
  WGPUBindGroupLayout layout = wgpuDeviceCreateBindGroupLayout(d->device, &ld);
  WGPUPipelineLayoutDescriptor pd = WGPU_PIPELINE_LAYOUT_DESCRIPTOR_INIT;
  pd.bindGroupLayoutCount = 1;
  pd.bindGroupLayouts = &layout;
  WGPUPipelineLayout pipelineLayout =
      wgpuDeviceCreatePipelineLayout(d->device, &pd);
  for (uint32_t i = 0; i < entryCount; i++) {
    p->names[i] = strdup(entries[i]);
    WGPUComputePipelineDescriptor cd = WGPU_COMPUTE_PIPELINE_DESCRIPTOR_INIT;
    cd.layout = pipelineLayout;
    cd.compute.module = module;
    cd.compute.entryPoint = sv(entries[i]);
    p->pipes[i] = wgpuDeviceCreateComputePipeline(d->device, &cd);
  }
  WGPUBindGroupDescriptor gd = WGPU_BIND_GROUP_DESCRIPTOR_INIT;
  gd.layout = layout;
  gd.entryCount = bindingCount;
  gd.entries = ge;
  p->group = wgpuDeviceCreateBindGroup(d->device, &gd);
  wgpuPipelineLayoutRelease(pipelineLayout);
  wgpuBindGroupLayoutRelease(layout);
  wgpuShaderModuleRelease(module);
  if (d->profile) {
    WGPUQuerySetDescriptor qd = WGPU_QUERY_SET_DESCRIPTOR_INIT;
    qd.type = WGPUQueryType_Timestamp;
    qd.count = PROFILE_DISPATCHES * 2;
    p->queries = wgpuDeviceCreateQuerySet(d->device, &qd);
    p->resolved = buffer(d, PROFILE_DISPATCHES * 16,
                         WGPUBufferUsage_QueryResolve |
                             WGPUBufferUsage_CopySrc);
    p->profileRead = buffer(d, PROFILE_DISPATCHES * 16,
                            WGPUBufferUsage_MapRead | WGPUBufferUsage_CopyDst);
  }
  wgpuDevicePoll(d->device, 1, NULL);
  if (d->error[0]) {
    // the program stays allocated: its objects may be referenced by wgpu
    return NULL;
  }
  return p;
}

// Writes [bytes] bytes of [source] at [offset] of binding [binding]. The
// write takes effect in queue order, before the next run.
EXPORT int32_t mpc_write(MpcProgram *p, uint32_t binding, uint64_t offset,
                         const void *source, uint64_t bytes) {
  if (binding >= p->bindingCount || offset + bytes > p->sizes[binding] ||
      (offset | bytes) & 3) {
    snprintf(p->d->error, sizeof p->d->error, "bad write");
    return 1;
  }
  if (bytes) wgpuQueueWriteBuffer(p->d->queue, p->buffers[binding], offset,
                                  source, bytes);
  return 0;
}

// Prints the time of each entry point and the ten longest dispatches.
static void report_profile(MpcProgram *p, const uint32_t *dispatches,
                           uint32_t timed) {
  MpcDevice *d = p->d;
  if (map_read(d, p->profileRead, timed * 16ull)) return;
  const uint64_t *ts =
      wgpuBufferGetConstMappedRange(p->profileRead, 0, timed * 16ull);
  double sum[MPC_MAX_ENTRIES] = {0};
  uint32_t n[MPC_MAX_ENTRIES] = {0};
  for (uint32_t k = 0; k < timed; k++) {
    uint32_t e = dispatches[k * 4];
    if (e >= p->entryCount) continue;
    sum[e] += (ts[k * 2 + 1] - ts[k * 2]) / 1e6;
    n[e]++;
  }
  fprintf(stderr, "profile: span %.2f ms;",
          (ts[(timed - 1) * 2 + 1] - ts[0]) / 1e6);
  for (uint32_t e = 0; e < p->entryCount; e++) {
    if (n[e]) fprintf(stderr, " %s %u %.2f ms;", p->names[e], n[e], sum[e]);
  }
  fprintf(stderr, "\n");
  uint32_t ranked[10];
  for (int r = 0; r < 10; r++) {
    double best = -1;
    uint32_t at = UINT32_MAX;
    for (uint32_t k = 0; k < timed; k++) {
      if (dispatches[k * 4] >= p->entryCount) continue;
      double ms = (ts[k * 2 + 1] - ts[k * 2]) / 1e6;
      int seen = 0;
      for (int q = 0; q < r; q++) seen |= ranked[q] == k;
      if (!seen && ms > best) best = ms, at = k;
    }
    ranked[r] = at;
    if (at == UINT32_MAX) break;
    fprintf(stderr, "  dispatch %u %s %ux%ux%u: %.2f ms\n", at,
            p->names[dispatches[at * 4]], dispatches[at * 4 + 1],
            dispatches[at * 4 + 2], dispatches[at * 4 + 3], best);
  }
  wgpuBufferUnmap(p->profileRead);
}

// Runs [count] dispatches of 4 words (entry point and workgroup counts x, y
// and z) in order in one compute pass. Dispatch k sees block k of [params],
// [paramStride] bytes each. Unless [wait], the run is only submitted.
// MPC_SKIP lists entry point indices (digits) to leave out.
EXPORT int32_t mpc_run(MpcProgram *p, const uint32_t *dispatches,
                       uint32_t count, const void *params, uint32_t wait) {
  MpcDevice *d = p->d;
  if (count > p->maxDispatches) {
    snprintf(d->error, sizeof d->error, "too many dispatches");
    return 1;
  }
  if (p->paramBinding != UINT32_MAX && count) {
    wgpuQueueWriteBuffer(d->queue, p->buffers[p->paramBinding], 0, params,
                         (uint64_t)count * p->paramStride);
  }
  WGPUCommandEncoder enc = wgpuDeviceCreateCommandEncoder(d->device, NULL);
  WGPUComputePassEncoder pass = wgpuCommandEncoderBeginComputePass(enc, NULL);
  const char *skip = getenv("MPC_SKIP");
  uint32_t last = UINT32_MAX;
  int bound = 0;
  for (uint32_t k = 0; k < count; k++) {
    const uint32_t *s = dispatches + k * 4;
    if (s[0] >= p->entryCount || !s[1] || !s[2] || !s[3]) continue;
    if (skip && strchr(skip, '0' + (int)s[0])) continue;
    if (s[0] != last) {
      wgpuComputePassEncoderSetPipeline(pass, p->pipes[s[0]]);
      last = s[0];
    }
    if (p->paramBinding != UINT32_MAX) {
      uint32_t offset = k * p->paramStride;
      wgpuComputePassEncoderSetBindGroup(pass, 0, p->group, 1, &offset);
    } else if (!bound) {
      wgpuComputePassEncoderSetBindGroup(pass, 0, p->group, 0, NULL);
      bound = 1;
    }
    if (d->profile && k < PROFILE_DISPATCHES) {
      wgpuComputePassEncoderWriteTimestamp(pass, p->queries, k * 2);
    }
    wgpuComputePassEncoderDispatchWorkgroups(pass, s[1], s[2], s[3]);
    if (d->profile && k < PROFILE_DISPATCHES) {
      wgpuComputePassEncoderWriteTimestamp(pass, p->queries, k * 2 + 1);
    }
  }
  wgpuComputePassEncoderEnd(pass);
  uint32_t timed = count < PROFILE_DISPATCHES ? count : PROFILE_DISPATCHES;
  if (d->profile && timed) {
    wgpuCommandEncoderResolveQuerySet(enc, p->queries, 0, timed * 2,
                                      p->resolved, 0);
    wgpuCommandEncoderCopyBufferToBuffer(enc, p->resolved, 0, p->profileRead,
                                         0, timed * 16ull);
  }
  WGPUCommandBuffer cmd = wgpuCommandEncoderFinish(enc, NULL);
  wgpuQueueSubmit(d->queue, 1, &cmd);
  wgpuCommandBufferRelease(cmd);
  wgpuComputePassEncoderRelease(pass);
  wgpuCommandEncoderRelease(enc);
  wgpuDevicePoll(d->device, wait || d->profile, NULL);
  if (d->profile && timed) report_profile(p, dispatches, timed);
  return d->error[0] ? 2 : 0;
}

// Waits for the work of the program and copies [bytes] bytes at [offset] of
// binding [binding] to [target].
EXPORT int32_t mpc_read(MpcProgram *p, uint32_t binding, uint64_t offset,
                        void *target, uint64_t bytes) {
  MpcDevice *d = p->d;
  if (binding >= p->bindingCount || offset + bytes > p->sizes[binding] ||
      (offset | bytes) & 3) {
    snprintf(d->error, sizeof d->error, "bad read");
    return 1;
  }
  if (!bytes) return 0;
  if (p->readbackSize < bytes) {
    if (p->readback) wgpuBufferRelease(p->readback);
    p->readback =
        buffer(d, bytes, WGPUBufferUsage_MapRead | WGPUBufferUsage_CopyDst);
    p->readbackSize = bytes;
  }
  WGPUCommandEncoder enc = wgpuDeviceCreateCommandEncoder(d->device, NULL);
  wgpuCommandEncoderCopyBufferToBuffer(enc, p->buffers[binding], offset,
                                       p->readback, 0, bytes);
  WGPUCommandBuffer cmd = wgpuCommandEncoderFinish(enc, NULL);
  wgpuQueueSubmit(d->queue, 1, &cmd);
  wgpuCommandBufferRelease(cmd);
  wgpuCommandEncoderRelease(enc);
  if (map_read(d, p->readback, bytes)) return 2;
  memcpy(target, wgpuBufferGetConstMappedRange(p->readback, 0, bytes), bytes);
  wgpuBufferUnmap(p->readback);
  return 0;
}

EXPORT void mpc_program_destroy(MpcProgram *p) {
  if (!p) return;
  wgpuDevicePoll(p->d->device, 1, NULL);
  for (uint32_t i = 0; i < p->entryCount; i++) {
    if (p->pipes[i]) wgpuComputePipelineRelease(p->pipes[i]);
    free(p->names[i]);
  }
  for (uint32_t i = 0; i < p->bindingCount; i++) {
    if (p->buffers[i]) wgpuBufferRelease(p->buffers[i]);
  }
  if (p->group) wgpuBindGroupRelease(p->group);
  if (p->readback) wgpuBufferRelease(p->readback);
  if (p->queries) wgpuQuerySetRelease(p->queries);
  if (p->resolved) wgpuBufferRelease(p->resolved);
  if (p->profileRead) wgpuBufferRelease(p->profileRead);
  free(p);
}

EXPORT void mpc_device_close(MpcDevice *d) {
  if (!d) return;
  if (d->queue) wgpuQueueRelease(d->queue);
  if (d->device) wgpuDeviceRelease(d->device);
  if (d->adapter) wgpuAdapterRelease(d->adapter);
  free(d);
}
