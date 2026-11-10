#define _POSIX_C_SOURCE 200809L

#include <inttypes.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <vulkan/vulkan.h>

enum { COMMAND_WORDS = 160, VRAM_BYTES = 4 * 1024 * 1024, CLUT_BYTES = 512 * 4 };
enum {
  BUFFER_VRAM, BUFFER_SNAPSHOT, BUFFER_COMMANDS, BUFFER_AUX, BUFFER_OUTPUT,
  BUFFER_TILES, BUFFER_COUNT
};
enum { TILE_MASK_CAPACITY = 1024 * 1024 };

typedef struct {
  VkBuffer buffer;
  VkDeviceMemory memory;
  VkDeviceSize size;
} Buffer;

static void fail(const char *message) {
  fprintf(stderr, "%s\n", message);
  exit(1);
}

#define VK(call) do { \
  VkResult result = (call); \
  if (result != VK_SUCCESS) { \
    fprintf(stderr, "%s failed: %d\n", #call, result); \
    exit(1); \
  } \
} while (0)

static double now_ms(void) {
  struct timespec value;
  clock_gettime(CLOCK_MONOTONIC, &value);
  return value.tv_sec * 1000.0 + value.tv_nsec / 1000000.0;
}

static void *read_file(const char *path, size_t *size) {
  FILE *file = fopen(path, "rb");
  if (!file || fseek(file, 0, SEEK_END)) fail(path);
  long length = ftell(file);
  if (length <= 0 || fseek(file, 0, SEEK_SET)) fail(path);
  *size = (size_t)length;
  void *data = malloc(*size);
  if (!data || fread(data, 1, *size, file) != *size) fail(path);
  fclose(file);
  return data;
}

static uint32_t choose_memory(VkPhysicalDevice physical, uint32_t types,
    VkMemoryPropertyFlags required) {
  VkPhysicalDeviceMemoryProperties properties;
  vkGetPhysicalDeviceMemoryProperties(physical, &properties);
  uint32_t fallback = UINT32_MAX;
  for (uint32_t i = 0; i < properties.memoryTypeCount; i++) {
    VkMemoryPropertyFlags flags = properties.memoryTypes[i].propertyFlags;
    if (!(types & (1u << i)) || (flags & required) != required) continue;
    if (flags & VK_MEMORY_PROPERTY_DEVICE_LOCAL_BIT) return i;
    if (fallback == UINT32_MAX) fallback = i;
  }
  if (fallback == UINT32_MAX) fail("required Vulkan buffer memory unavailable");
  return fallback;
}

static Buffer make_buffer(VkPhysicalDevice physical, VkDevice device, VkDeviceSize size,
    VkBufferUsageFlags extra, const void *initial, int host_visible) {
  Buffer buffer = {.size = size};
  VkBufferCreateInfo info = {VK_STRUCTURE_TYPE_BUFFER_CREATE_INFO, .size = size,
    .usage = VK_BUFFER_USAGE_STORAGE_BUFFER_BIT | extra};
  VK(vkCreateBuffer(device, &info, NULL, &buffer.buffer));
  VkMemoryRequirements needs;
  vkGetBufferMemoryRequirements(device, buffer.buffer, &needs);
  VkMemoryPropertyFlags flags = host_visible ?
      VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT | VK_MEMORY_PROPERTY_HOST_COHERENT_BIT : 0;
  VkMemoryAllocateInfo memory = {VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO,
    .allocationSize = needs.size, .memoryTypeIndex = choose_memory(physical, needs.memoryTypeBits, flags)};
  VK(vkAllocateMemory(device, &memory, NULL, &buffer.memory));
  VK(vkBindBufferMemory(device, buffer.buffer, buffer.memory, 0));
  if (initial) {
    void *mapping;
    VK(vkMapMemory(device, buffer.memory, 0, size, 0, &mapping));
    memcpy(mapping, initial, size);
    vkUnmapMemory(device, buffer.memory);
  }
  return buffer;
}

static void barrier(VkCommandBuffer commands, VkPipelineStageFlags src_stage,
    VkAccessFlags src_access, VkPipelineStageFlags dst_stage, VkAccessFlags dst_access) {
  VkMemoryBarrier memory = {VK_STRUCTURE_TYPE_MEMORY_BARRIER,
    .srcAccessMask = src_access, .dstAccessMask = dst_access};
  vkCmdPipelineBarrier(commands, src_stage, dst_stage, 0, 1, &memory, 0, NULL, 0, NULL);
}

typedef struct {
  uint32_t start, end;
} Span;

typedef struct {
  Span color, depth, texture;
} DrawUse;

static float as_float(uint32_t value) {
  float result;
  memcpy(&result, &value, sizeof(result));
  return result;
}

static int spans_overlap(Span a, Span b) {
  return a.start < a.end && b.start < b.end && a.start < b.end && b.start < a.end;
}

static int footprint(const uint32_t *aux, uint32_t psm, uint32_t base,
    uint32_t pages, uint32_t x, uint32_t y, uint32_t width, uint32_t height, Span *span) {
  if (!width || !height || psm >= 64) return 0;
  const uint32_t *layout = aux + psm * 4;
  uint32_t xbits = layout[1], ybits = layout[2];
  uint32_t last_x = (x + width - 1) >> xbits;
  if (last_x >= pages) return 0;
  uint32_t first = (y >> ybits) * pages + (x >> xbits);
  uint32_t last = ((y + height - 1) >> ybits) * pages + last_x;
  *span = (Span){base + first * 32, base + (last + 1) * 32};
  return span->end <= VRAM_BYTES / 256;
}

static int use_for_draw(const uint32_t *aux, const uint32_t *draw, DrawUse *use) {
  *use = (DrawUse){0};
  if (draw[146] || draw[132] || draw[147] || draw[148] != draw[115]) return 0;
  if (!footprint(aux, draw[116], draw[117], draw[118], draw[112], draw[113],
      draw[114], draw[115], &use->color)) return 0;
  if (as_float(draw[5]) >= 2 || as_float(draw[26]) != 0) {
    if (!footprint(aux, draw[121], draw[122], draw[123], draw[112], draw[113],
        draw[114], draw[115], &use->depth)) return 0;
  }
  if (as_float(draw[12]) >= 0) {
    if (as_float(draw[104]) != 0) return 0;
    uint32_t width = (uint32_t)as_float(draw[28]), height = (uint32_t)as_float(draw[29]);
    uint32_t wrap = (uint32_t)as_float(draw[30]);
    for (unsigned axis = 0; axis < 2; axis++) {
      uint32_t mode = (wrap >> (axis * 2)) & 3;
      uint32_t size = axis ? height : width;
      uint32_t lo = (uint32_t)as_float(draw[72 + axis]);
      uint32_t hi = (uint32_t)as_float(draw[74 + axis]);
      if ((mode == 2 && (lo >= size || hi >= size)) ||
          (mode == 3 && (lo | hi) >= size)) return 0;
    }
    if (!footprint(aux, draw[124], draw[125], draw[126], 0, 0, width, height,
        &use->texture)) return 0;
  }
  return !spans_overlap(use->color, use->depth) &&
      !spans_overlap(use->color, use->texture) && !spans_overlap(use->depth, use->texture);
}

static int can_share_draw_target(DrawUse a, DrawUse b) {
  return !spans_overlap(a.color, b.depth) && !spans_overlap(a.depth, b.color) &&
      !spans_overlap(a.color, b.texture) && !spans_overlap(a.depth, b.texture) &&
      !spans_overlap(b.color, a.texture) && !spans_overlap(b.depth, a.texture);
}

static uint32_t min_u32(uint32_t a, uint32_t b) { return a < b ? a : b; }
static uint32_t max_u32(uint32_t a, uint32_t b) { return a > b ? a : b; }

static void copy_to_buffer(VkDevice device, Buffer buffer, const void *data, size_t size) {
  if (size > buffer.size) fail("GS stream buffer capacity exceeded");
  void *mapped;
  VK(vkMapMemory(device, buffer.memory, 0, size, 0, &mapped));
  memcpy(mapped, data, size);
  vkUnmapMemory(device, buffer.memory);
}

static void pipe_write(const void *data, size_t size) {
  if (fwrite(data, 1, size, stdout) != size) fail("GS stream output closed");
}

static void pipe_read(void *data, size_t size) {
  if (fread(data, 1, size, stdin) != size) fail("incomplete GS stream frame");
}

int main(int argc, char **argv) {
  int stream = argc == 3 && !strcmp(argv[1], "--stream");
  if (!stream && argc != 6) fail("usage: gs-resident SHADER START COMMANDS AUX RGBA | --stream SHADER");
  size_t shader_size, command_size = 0, aux_size = 0, initial_size = 0;
  const size_t vram_size = VRAM_BYTES + CLUT_BYTES;
  uint32_t *shader = read_file(argv[stream ? 2 : 1], &shader_size);
  void *initial = stream ? malloc(vram_size) : read_file(argv[2], &initial_size);
  const size_t stream_capacity = 16 * 1024 * 1024;
  uint32_t *commands = stream ? malloc(stream_capacity) : read_file(argv[3], &command_size);
  uint32_t *aux = stream ? malloc(stream_capacity) : read_file(argv[4], &aux_size);
  if (!initial || !commands || !aux || shader_size % 4 ||
      (!stream && initial_size != vram_size)) fail("invalid replay input");

  VkApplicationInfo app = {VK_STRUCTURE_TYPE_APPLICATION_INFO,
    .pApplicationName = "fnesemu GS trace", .apiVersion = VK_API_VERSION_1_1};
  VkInstanceCreateInfo instance_info = {VK_STRUCTURE_TYPE_INSTANCE_CREATE_INFO,
    .pApplicationInfo = &app};
  VkInstance instance;
  VK(vkCreateInstance(&instance_info, NULL, &instance));
  uint32_t physical_count;
  VK(vkEnumeratePhysicalDevices(instance, &physical_count, NULL));
  if (!physical_count) fail("no Vulkan device");
  VkPhysicalDevice *devices = calloc(physical_count, sizeof(*devices));
  VK(vkEnumeratePhysicalDevices(instance, &physical_count, devices));
  VkPhysicalDevice physical = VK_NULL_HANDLE;
  VkPhysicalDeviceProperties properties;
  uint32_t family = 0;
  const char *match = getenv("FNES_GS_GPU");
  for (uint32_t i = 0; i < physical_count; i++) {
    VkPhysicalDeviceProperties candidate;
    vkGetPhysicalDeviceProperties(devices[i], &candidate);
    if (candidate.deviceType == VK_PHYSICAL_DEVICE_TYPE_CPU ||
        (match && !strstr(candidate.deviceName, match))) continue;
    uint32_t families;
    vkGetPhysicalDeviceQueueFamilyProperties(devices[i], &families, NULL);
    VkQueueFamilyProperties *queues = calloc(families, sizeof(*queues));
    vkGetPhysicalDeviceQueueFamilyProperties(devices[i], &families, queues);
    for (uint32_t j = 0; j < families; j++) {
      if (!(queues[j].queueFlags & VK_QUEUE_COMPUTE_BIT)) continue;
      physical = devices[i];
      properties = candidate;
      family = j;
      break;
    }
    free(queues);
    if (physical) break;
  }
  free(devices);
  if (!physical) fail("no matching hardware Vulkan compute device");
  fprintf(stderr, "GPU: %s\n", properties.deviceName);
  float priority = 1;
  VkDeviceQueueCreateInfo queue_info = {VK_STRUCTURE_TYPE_DEVICE_QUEUE_CREATE_INFO,
    .queueFamilyIndex = family, .queueCount = 1, .pQueuePriorities = &priority};
  VkDeviceCreateInfo device_info = {VK_STRUCTURE_TYPE_DEVICE_CREATE_INFO,
    .queueCreateInfoCount = 1, .pQueueCreateInfos = &queue_info};
  VkDevice device;
  VK(vkCreateDevice(physical, &device_info, NULL, &device));
  VkQueue queue;
  vkGetDeviceQueue(device, family, 0, &queue);

  double start;
  Buffer upload = make_buffer(physical, device, vram_size,
      VK_BUFFER_USAGE_TRANSFER_SRC_BIT, NULL, 1);
  Buffer buffers[BUFFER_COUNT] = {
    make_buffer(physical, device, vram_size,
        VK_BUFFER_USAGE_TRANSFER_SRC_BIT | VK_BUFFER_USAGE_TRANSFER_DST_BIT, NULL, 0),
    make_buffer(physical, device, VRAM_BYTES, VK_BUFFER_USAGE_TRANSFER_DST_BIT, NULL, 0),
    make_buffer(physical, device, stream ? stream_capacity : command_size, 0, NULL, 1),
    make_buffer(physical, device, stream ? stream_capacity : aux_size, 0, NULL, 1),
    make_buffer(physical, device, 2048 * 2048 * 4, 0, NULL, 1),
    make_buffer(physical, device, TILE_MASK_CAPACITY * sizeof(uint32_t), 0, NULL, 1),
  };
  void *tile_mapping;
  VK(vkMapMemory(device, buffers[BUFFER_TILES].memory, 0,
      buffers[BUFFER_TILES].size, 0, &tile_mapping));
  uint32_t *tile_masks = tile_mapping;
  VkDescriptorSetLayoutBinding bindings[BUFFER_COUNT];
  for (uint32_t i = 0; i < BUFFER_COUNT; i++) {
    bindings[i] = (VkDescriptorSetLayoutBinding){i, VK_DESCRIPTOR_TYPE_STORAGE_BUFFER, 1,
      VK_SHADER_STAGE_COMPUTE_BIT, NULL};
  }
  VkDescriptorSetLayoutCreateInfo layout_info = {VK_STRUCTURE_TYPE_DESCRIPTOR_SET_LAYOUT_CREATE_INFO,
    .bindingCount = BUFFER_COUNT, .pBindings = bindings};
  VkDescriptorSetLayout layout;
  VK(vkCreateDescriptorSetLayout(device, &layout_info, NULL, &layout));
  VkPushConstantRange push = {VK_SHADER_STAGE_COMPUTE_BIT, 0, 20};
  VkPipelineLayoutCreateInfo pipeline_layout_info = {VK_STRUCTURE_TYPE_PIPELINE_LAYOUT_CREATE_INFO,
    .setLayoutCount = 1, .pSetLayouts = &layout, .pushConstantRangeCount = 1,
    .pPushConstantRanges = &push};
  VkPipelineLayout pipeline_layout;
  VK(vkCreatePipelineLayout(device, &pipeline_layout_info, NULL, &pipeline_layout));
  VkShaderModuleCreateInfo module_info = {VK_STRUCTURE_TYPE_SHADER_MODULE_CREATE_INFO,
    .codeSize = shader_size, .pCode = shader};
  VkShaderModule module;
  VK(vkCreateShaderModule(device, &module_info, NULL, &module));
  VkComputePipelineCreateInfo pipeline_info = {VK_STRUCTURE_TYPE_COMPUTE_PIPELINE_CREATE_INFO,
    .stage = {VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO,
      .stage = VK_SHADER_STAGE_COMPUTE_BIT, .module = module, .pName = "main"},
    .layout = pipeline_layout};
  VkPipeline pipeline;
  start = now_ms();
  VK(vkCreateComputePipelines(device, VK_NULL_HANDLE, 1, &pipeline_info, NULL, &pipeline));
  double pipeline_ms = now_ms() - start;

  VkDescriptorPoolSize pool_size = {VK_DESCRIPTOR_TYPE_STORAGE_BUFFER, BUFFER_COUNT};
  VkDescriptorPoolCreateInfo pool_info = {VK_STRUCTURE_TYPE_DESCRIPTOR_POOL_CREATE_INFO,
    .maxSets = 1, .poolSizeCount = 1, .pPoolSizes = &pool_size};
  VkDescriptorPool descriptors;
  VK(vkCreateDescriptorPool(device, &pool_info, NULL, &descriptors));
  VkDescriptorSetAllocateInfo set_info = {VK_STRUCTURE_TYPE_DESCRIPTOR_SET_ALLOCATE_INFO,
    .descriptorPool = descriptors, .descriptorSetCount = 1, .pSetLayouts = &layout};
  VkDescriptorSet set;
  VK(vkAllocateDescriptorSets(device, &set_info, &set));
  VkDescriptorBufferInfo infos[BUFFER_COUNT];
  VkWriteDescriptorSet writes[BUFFER_COUNT];
  for (uint32_t i = 0; i < BUFFER_COUNT; i++) {
    infos[i] = (VkDescriptorBufferInfo){buffers[i].buffer, 0, buffers[i].size};
    writes[i] = (VkWriteDescriptorSet){VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET,
      .dstSet = set, .dstBinding = i, .descriptorCount = 1,
      .descriptorType = VK_DESCRIPTOR_TYPE_STORAGE_BUFFER, .pBufferInfo = &infos[i]};
  }
  vkUpdateDescriptorSets(device, BUFFER_COUNT, writes, 0, NULL);
  VkCommandPoolCreateInfo command_pool_info = {VK_STRUCTURE_TYPE_COMMAND_POOL_CREATE_INFO,
    .queueFamilyIndex = family};
  VkCommandPool command_pool;
  VK(vkCreateCommandPool(device, &command_pool_info, NULL, &command_pool));
  VkCommandBufferAllocateInfo cb_info = {VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO,
    .commandPool = command_pool, .level = VK_COMMAND_BUFFER_LEVEL_PRIMARY, .commandBufferCount = 1};
  VkCommandBuffer cb;
  VK(vkAllocateCommandBuffers(device, &cb_info, &cb));

  VkFenceCreateInfo fence_info = {VK_STRUCTURE_TYPE_FENCE_CREATE_INFO};
  VkFence fence;
  VK(vkCreateFence(device, &fence_info, NULL, &fence));
  VkSubmitInfo submit = {VK_STRUCTURE_TYPE_SUBMIT_INFO,
    .commandBufferCount = 1, .pCommandBuffers = &cb};
  if (stream) {
    pipe_write("GSR1", 4);
    fflush(stdout);
  }
  for (uint32_t frame = 0;; frame++) {
    if (stream) {
      uint32_t header[3];
      if (fread(header, sizeof(uint32_t), 3, stdin) != 3) {
        if (feof(stdin)) break;
        fail("invalid GS stream header");
      }
      initial_size = header[0];
      command_size = header[1];
      aux_size = header[2];
      if ((initial_size && initial_size != vram_size) || (!frame && !initial_size) ||
          command_size > stream_capacity || aux_size > stream_capacity) fail("invalid GS stream sizes");
      if (initial_size) pipe_read(initial, initial_size);
      pipe_read(commands, command_size);
      pipe_read(aux, aux_size);
    }
    if (!command_size || command_size % (4 * COMMAND_WORDS) || aux_size < 1024 ||
        aux_size % 4) fail("invalid GS commands");
    uint32_t count = command_size / (4 * COMMAND_WORDS);
    const uint32_t *scan = commands + (count - 1) * COMMAND_WORDS;
    if (scan[146] != 3 || !scan[114] || !scan[115] ||
        scan[114] > 2048 || scan[115] > 2048) fail("missing or invalid scanout");
    size_t output_size = (size_t)scan[114] * scan[115] * 4;
    start = now_ms();
    if (initial_size) copy_to_buffer(device, upload, initial, initial_size);
    copy_to_buffer(device, buffers[BUFFER_COMMANDS], commands, command_size);
    copy_to_buffer(device, buffers[BUFFER_AUX], aux, aux_size);
    double upload_ms = now_ms() - start;
    if (frame) VK(vkResetCommandPool(device, command_pool, 0));
    start = now_ms();
    VkCommandBufferBeginInfo begin = {VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO};
    VK(vkBeginCommandBuffer(cb, &begin));
    if (initial_size) {
      VkBufferCopy init_copy = {0, 0, vram_size};
      vkCmdCopyBuffer(cb, upload.buffer, buffers[BUFFER_VRAM].buffer, 1, &init_copy);
      barrier(cb, VK_PIPELINE_STAGE_TRANSFER_BIT, VK_ACCESS_TRANSFER_WRITE_BIT,
          VK_PIPELINE_STAGE_COMPUTE_SHADER_BIT | VK_PIPELINE_STAGE_TRANSFER_BIT,
          VK_ACCESS_SHADER_READ_BIT | VK_ACCESS_SHADER_WRITE_BIT | VK_ACCESS_TRANSFER_READ_BIT);
    } else {
      barrier(cb, VK_PIPELINE_STAGE_COMPUTE_SHADER_BIT, VK_ACCESS_SHADER_WRITE_BIT,
          VK_PIPELINE_STAGE_COMPUTE_SHADER_BIT | VK_PIPELINE_STAGE_TRANSFER_BIT,
          VK_ACCESS_SHADER_READ_BIT | VK_ACCESS_SHADER_WRITE_BIT | VK_ACCESS_TRANSFER_READ_BIT);
    }
    vkCmdBindPipeline(cb, VK_PIPELINE_BIND_POINT_COMPUTE, pipeline);
    vkCmdBindDescriptorSets(cb, VK_PIPELINE_BIND_POINT_COMPUTE, pipeline_layout, 0, 1, &set, 0, NULL);
    uint32_t snapshots = 0, dispatches = 0, grouped = 0, tile_count = 0;
    uint64_t snapshot_bytes = 0;
    const char *group_setting = getenv("FNES_GS_GROUP");
    uint32_t group_limit = group_setting ? (uint32_t)atoi(group_setting) : 32;
    group_limit = max_u32(1, min_u32(32, group_limit));
    for (uint32_t i = 0; i < count; i++) {
      const uint32_t *draw = commands + i * COMMAND_WORDS;
      uint32_t op = draw[146];
      if (op > 3) fail("unknown command");
      uint32_t first = i, group_count = 1;
      uint32_t left = draw[112], top = draw[113];
      uint32_t right = left + draw[114], bottom = top + draw[115];
      uint64_t area = (uint64_t)draw[114] * draw[115];
      DrawUse uses[32];
      if (group_limit > 1 && use_for_draw(aux, draw, &uses[0])) {
        for (; group_count < group_limit && first + group_count < count; group_count++) {
          const uint32_t *next = commands + (first + group_count) * COMMAND_WORDS;
          if (memcmp(draw + 116, next + 116, 3 * sizeof(uint32_t)) ||
              memcmp(draw + 121, next + 121, 3 * sizeof(uint32_t))) break;
          DrawUse candidate;
          if (!use_for_draw(aux, next, &candidate)) break;
          uint32_t prior;
          for (prior = 0; prior < group_count; prior++) {
            if (!can_share_draw_target(uses[prior], candidate)) break;
          }
          if (prior < group_count) break;
          uint32_t l = min_u32(left, next[112]), t = min_u32(top, next[113]);
          uint32_t r = max_u32(right, next[112] + next[114]);
          uint32_t b = max_u32(bottom, next[113] + next[115]);
          uint64_t added = (uint64_t)next[114] * next[115];
          if ((uint64_t)(r - l) * (b - t) > (area + added) * 2 ||
              r - l > 512 || b - t > 512) break;
          uses[group_count] = candidate;
          left = l; top = t; right = r; bottom = b;
          area += added;
        }
      }
      int snapshot = op == 0 && draw[132];
      if (i) {
        barrier(cb, VK_PIPELINE_STAGE_COMPUTE_SHADER_BIT,
          VK_ACCESS_SHADER_READ_BIT | VK_ACCESS_SHADER_WRITE_BIT,
          snapshot ? VK_PIPELINE_STAGE_TRANSFER_BIT : VK_PIPELINE_STAGE_COMPUTE_SHADER_BIT,
          snapshot ? VK_ACCESS_TRANSFER_READ_BIT | VK_ACCESS_TRANSFER_WRITE_BIT :
              VK_ACCESS_SHADER_READ_BIT | VK_ACCESS_SHADER_WRITE_BIT);
      }
      if (snapshot) {
        if (draw[149] >= draw[150] || draw[150] > VRAM_BYTES / 4) fail("invalid snapshot");
        VkBufferCopy copy = {(VkDeviceSize)draw[149] * 4, (VkDeviceSize)draw[149] * 4,
          (VkDeviceSize)(draw[150] - draw[149]) * 4};
        vkCmdCopyBuffer(cb, buffers[BUFFER_VRAM].buffer, buffers[BUFFER_SNAPSHOT].buffer, 1, &copy);
        barrier(cb, VK_PIPELINE_STAGE_TRANSFER_BIT, VK_ACCESS_TRANSFER_WRITE_BIT,
          VK_PIPELINE_STAGE_COMPUTE_SHADER_BIT, VK_ACCESS_SHADER_READ_BIT | VK_ACCESS_SHADER_WRITE_BIT);
        snapshots++;
        snapshot_bytes += copy.size;
      }
      uint32_t tile_width = (right - left + 7) / 8;
      uint32_t tile_height = (bottom - top + 7) / 8;
      uint32_t tile_offset = UINT32_MAX;
      if (group_count > 1 && tile_width * tile_height <= TILE_MASK_CAPACITY - tile_count) {
        tile_offset = tile_count;
        uint32_t *masks = tile_masks + tile_offset;
        tile_count += tile_width * tile_height;
        memset(masks, 0, tile_width * tile_height * sizeof(*masks));
        for (uint32_t n = 0; n < group_count; n++) {
          const uint32_t *part = commands + (first + n) * COMMAND_WORDS;
          uint32_t x0 = (part[112] - left) / 8;
          uint32_t y0 = (part[113] - top) / 8;
          uint32_t x1 = (part[112] - left + part[114] - 1) / 8;
          uint32_t y1 = (part[113] - top + part[115] - 1) / 8;
          for (uint32_t y = y0; y <= y1; y++) {
            for (uint32_t x = x0; x <= x1; x++) masks[y * tile_width + x] |= 1u << n;
          }
        }
      }
      uint32_t parameters[] = {first, group_count, left, top, tile_offset};
      vkCmdPushConstants(cb, pipeline_layout, VK_SHADER_STAGE_COMPUTE_BIT,
          0, sizeof(parameters), parameters);
      if (group_count > 1) {
        vkCmdDispatch(cb, tile_width, tile_height, 1);
        grouped += group_count;
        i += group_count - 1;
      } else if (op == 1 || op == 2) {
        vkCmdDispatch(cb, (draw[148] + 63) / 64, 1, 1);
      } else {
        uint32_t height = op == 0 ? draw[148] - draw[147] : draw[115];
        vkCmdDispatch(cb, (draw[114] + 7) / 8, (height + 7) / 8, 1);
      }
      dispatches++;
    }
    barrier(cb, VK_PIPELINE_STAGE_COMPUTE_SHADER_BIT, VK_ACCESS_SHADER_WRITE_BIT,
        VK_PIPELINE_STAGE_HOST_BIT, VK_ACCESS_HOST_READ_BIT);
    VK(vkEndCommandBuffer(cb));
    double record_ms = now_ms() - start;

    const char *repeat_setting = getenv("FNES_GS_REPEATS");
    uint32_t repeats = stream ? 1 : repeat_setting ? (uint32_t)atoi(repeat_setting) : 4;
    repeats = max_u32(1, min_u32(20, repeats));
    double samples[20];
    for (uint32_t i = 0; i < repeats; i++) {
      if (frame || i) VK(vkResetFences(device, 1, &fence));
      start = now_ms();
      VK(vkQueueSubmit(queue, 1, &submit, fence));
      VK(vkWaitForFences(device, 1, &fence, VK_TRUE, UINT64_C(300000000000)));
      samples[i] = now_ms() - start;
    }
    start = now_ms();
    void *output;
    VK(vkMapMemory(device, buffers[BUFFER_OUTPUT].memory, 0, output_size, 0, &output));
    double read_ms = now_ms() - start;
    char response[1200];
    int length = snprintf(response, sizeof(response),
        "{\"commands\":%u,\"dispatches\":%u,\"groupedDraws\":%u,\"tiles\":%u,"
        "\"snapshotCopies\":%u,\"snapshotBytes\":%" PRIu64
        ",\"submissions\":1,\"readbacks\":1,"
        "\"uploadMs\":%.3f,\"pipelineMs\":%.3f,\"commandRecordMs\":%.3f,"
        "\"scanoutMapMs\":%.3f,\"submitSamplesMs\":[",
        count, dispatches, grouped, tile_count, snapshots, snapshot_bytes, upload_ms,
        frame ? 0 : pipeline_ms, record_ms, read_ms);
    for (uint32_t i = 0; i < repeats; i++) {
      length += snprintf(response + length, sizeof(response) - length, "%s%.3f",
          i ? "," : "", samples[i]);
    }
    length += snprintf(response + length, sizeof(response) - length, "]}");
    if (stream) {
      uint32_t header[] = {(uint32_t)length, (uint32_t)output_size};
      pipe_write(header, sizeof(header));
      pipe_write(response, length);
      pipe_write(output, output_size);
      fflush(stdout);
    } else {
      FILE *file = fopen(argv[5], "wb");
      if (!file || fwrite(output, 1, output_size, file) != output_size || fclose(file)) {
        fail("scanout write failed");
      }
      puts(response);
    }
    vkUnmapMemory(device, buffers[BUFFER_OUTPUT].memory);
    if (!stream) break;
  }
  vkUnmapMemory(device, buffers[BUFFER_TILES].memory);
  vkDestroyFence(device, fence, NULL);
  vkDestroyCommandPool(device, command_pool, NULL);
  vkDestroyDescriptorPool(device, descriptors, NULL);
  vkDestroyPipeline(device, pipeline, NULL);
  vkDestroyShaderModule(device, module, NULL);
  vkDestroyPipelineLayout(device, pipeline_layout, NULL);
  vkDestroyDescriptorSetLayout(device, layout, NULL);
  for (uint32_t i = 0; i < BUFFER_COUNT; i++) {
    vkDestroyBuffer(device, buffers[i].buffer, NULL);
    vkFreeMemory(device, buffers[i].memory, NULL);
  }
  vkDestroyBuffer(device, upload.buffer, NULL);
  vkFreeMemory(device, upload.memory, NULL);
  vkDestroyDevice(device, NULL);
  vkDestroyInstance(instance, NULL);
  free(shader);
  free(initial);
  free(commands);
  free(aux);
  return 0;
}
