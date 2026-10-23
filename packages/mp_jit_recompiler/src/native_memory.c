#include <stdint.h>
#include <stddef.h>
#include <string.h>
#if defined(_WIN32)
#include <windows.h>
#define EXPORT __declspec(dllexport)
#else
#include <sys/mman.h>
#include <unistd.h>
#define EXPORT __attribute__((visibility("default"))) __attribute__((used))
#if defined(__APPLE__)
#include <pthread.h>
#include <libkern/OSCacheControl.h>
#endif
#endif

#if defined(__APPLE__)
/* Hardened processes permit one MAP_JIT region. Reserve one arena and reuse
 * fixed slots across CPU runtimes; publication remains thread-local. */
#define JIT_SLOT_SIZE ((uintptr_t)64 << 20)
#define JIT_SLOT_COUNT 32
static void *jit_arena;
static uint32_t jit_slots;
static pthread_mutex_t jit_mutex = PTHREAD_MUTEX_INITIALIZER;

static void *alloc_jit(intptr_t size) {
  if ((uintptr_t)size > JIT_SLOT_SIZE) return NULL;
  pthread_mutex_lock(&jit_mutex);
  if (!jit_arena) {
    void *p = mmap(NULL, JIT_SLOT_SIZE * JIT_SLOT_COUNT,
                  PROT_READ | PROT_WRITE | PROT_EXEC,
                  MAP_PRIVATE | MAP_ANONYMOUS | MAP_JIT, -1, 0);
    if (p != MAP_FAILED) jit_arena = p;
  }
  void *result = NULL;
  if (jit_arena) {
    for (unsigned i = 0; i < JIT_SLOT_COUNT; i++) {
      const uint32_t bit = UINT32_C(1) << i;
      if (!(jit_slots & bit)) {
        jit_slots |= bit;
        result = (char *)jit_arena + JIT_SLOT_SIZE * i;
        break;
      }
    }
  }
  pthread_mutex_unlock(&jit_mutex);
  return result;
}

static int free_jit(void *p) {
  pthread_mutex_lock(&jit_mutex);
  const uintptr_t offset = (uintptr_t)p - (uintptr_t)jit_arena;
  const int found = jit_arena && offset < JIT_SLOT_SIZE * JIT_SLOT_COUNT &&
                    offset % JIT_SLOT_SIZE == 0;
  if (found) {
    jit_slots &= ~(UINT32_C(1) << (offset / JIT_SLOT_SIZE));
    madvise(p, JIT_SLOT_SIZE, MADV_DONTNEED);
  }
  pthread_mutex_unlock(&jit_mutex);
  return found;
}
#endif

EXPORT intptr_t mp_jit_page_size(void) {
#if defined(_WIN32)
  SYSTEM_INFO info;
  GetSystemInfo(&info);
  return info.dwPageSize;
#else
  return getpagesize();
#endif
}

EXPORT void *mp_jit_alloc(intptr_t size, int32_t code) {
  (void)code;
#if defined(_WIN32)
  return VirtualAlloc(NULL, size, MEM_COMMIT | MEM_RESERVE, PAGE_READWRITE);
#else
  int flags = MAP_PRIVATE | MAP_ANONYMOUS;
  int prot = PROT_READ | PROT_WRITE;
#if defined(__APPLE__)
  if (code) return alloc_jit(size);
#endif
  void *p = mmap(NULL, size, prot, flags, -1, 0);
  return p == MAP_FAILED ? NULL : p;
#endif
}

EXPORT void mp_jit_free(void *p, intptr_t size) {
  (void)size;
#if defined(_WIN32)
  VirtualFree(p, 0, MEM_RELEASE);
#else
#if defined(__APPLE__)
  if (free_jit(p)) return;
#endif
  munmap(p, size);
#endif
}

/* No Dart callback may run while JIT memory is writable on this thread. */
EXPORT int32_t mp_jit_write(void *target, const void *source, intptr_t size) {
#if defined(__APPLE__)
#if defined(__aarch64__)
  pthread_jit_write_protect_np(0);
#endif
  memcpy(target, source, size);
  sys_icache_invalidate(target, size);
#if defined(__aarch64__)
  pthread_jit_write_protect_np(1);
#endif
  return 1;
#elif defined(_WIN32)
  DWORD old;
  if (!VirtualProtect(target, size, PAGE_READWRITE, &old)) return 0;
  memcpy(target, source, size);
  if (!VirtualProtect(target, size, PAGE_EXECUTE_READ, &old)) return 0;
  return FlushInstructionCache(GetCurrentProcess(), target, size) != 0;
#else
  const uintptr_t page = (uintptr_t)mp_jit_page_size();
  const uintptr_t start = (uintptr_t)target & ~(page - 1);
  const uintptr_t end = ((uintptr_t)target + size + page - 1) & ~(page - 1);
  if (mprotect((void *)start, end - start, PROT_READ | PROT_WRITE)) return 0;
  memcpy(target, source, size);
  __builtin___clear_cache((char *)target, (char *)target + size);
  return mprotect((void *)start, end - start, PROT_READ | PROT_EXEC) == 0;
#endif
}
