// The H.264 decoder of macOS and iOS: a VideoToolbox decompression session
// behind a small C interface for Dart. VideoToolbox gives its pictures to
// a callback, which may run on a thread of its own, so this side keeps the
// latest picture under a lock and Dart copies it out after a decode.
//
// The units come as Annex B byte streams. The parameter sets make the
// format description of the session, and the other NAL units go to the
// decoder with four-byte lengths in place of the start codes.

#include <CoreFoundation/CoreFoundation.h>
#include <CoreMedia/CoreMedia.h>
#include <CoreVideo/CoreVideo.h>
#include <VideoToolbox/VideoToolbox.h>
#include <pthread.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>

#define EXPORT __attribute__((visibility("default")))

typedef struct {
  VTDecompressionSessionRef session;
  CMVideoFormatDescriptionRef format;
  uint8_t *sps, *pps;
  size_t spsLength, ppsLength;
  // whether the parameter sets changed since the session was made
  int changed;
  pthread_mutex_t lock;
  CVPixelBufferRef latest;
  int64_t time;
} MmdVt;

static void output(void *context, void *frame, OSStatus status,
                   VTDecodeInfoFlags flags, CVImageBufferRef image,
                   CMTime pts, CMTime duration) {
  (void)frame;
  (void)flags;
  (void)pts;
  (void)duration;
  MmdVt *vt = context;
  if (status != noErr || image == NULL) return;
  CVPixelBufferRetain(image);
  pthread_mutex_lock(&vt->lock);
  if (vt->latest) CVPixelBufferRelease(vt->latest);
  vt->latest = image;
  pthread_mutex_unlock(&vt->lock);
}

static void closeSession(MmdVt *vt) {
  if (vt->session) {
    VTDecompressionSessionInvalidate(vt->session);
    CFRelease(vt->session);
    vt->session = NULL;
  }
  if (vt->format) {
    CFRelease(vt->format);
    vt->format = NULL;
  }
}

/// Makes the session for the parameter sets; zero when it cannot.
static int openSession(MmdVt *vt) {
  closeSession(vt);
  if (!vt->sps || !vt->pps) return 0;
  const uint8_t *sets[2] = {vt->sps, vt->pps};
  const size_t sizes[2] = {vt->spsLength, vt->ppsLength};
  if (CMVideoFormatDescriptionCreateFromH264ParameterSets(
          kCFAllocatorDefault, 2, sets, sizes, 4, &vt->format) != noErr) {
    vt->format = NULL;
    return 0;
  }
  // pictures in BGRA, so that Dart only swaps two bytes
  int32_t pixelFormat = kCVPixelFormatType_32BGRA;
  CFNumberRef number =
      CFNumberCreate(kCFAllocatorDefault, kCFNumberSInt32Type, &pixelFormat);
  const void *keys[1] = {kCVPixelBufferPixelFormatTypeKey};
  const void *values[1] = {number};
  CFDictionaryRef attributes = CFDictionaryCreate(
      kCFAllocatorDefault, keys, values, 1, &kCFTypeDictionaryKeyCallBacks,
      &kCFTypeDictionaryValueCallBacks);
  CFRelease(number);
  VTDecompressionOutputCallbackRecord callback = {output, vt};
  OSStatus status = VTDecompressionSessionCreate(
      kCFAllocatorDefault, vt->format, NULL, attributes, &callback,
      &vt->session);
  CFRelease(attributes);
  if (status != noErr) {
    vt->session = NULL;
    closeSession(vt);
    return 0;
  }
  vt->changed = 0;
  return 1;
}

/// Keeps a copy of a parameter set in [slot]; marks a change.
static void keep(MmdVt *vt, uint8_t **slot, size_t *length,
                 const uint8_t *nal, size_t size) {
  if (*slot && *length == size && memcmp(*slot, nal, size) == 0) return;
  uint8_t *copy = malloc(size);
  if (!copy) return;
  memcpy(copy, nal, size);
  free(*slot);
  *slot = copy;
  *length = size;
  vt->changed = 1;
}

/// The offset of the NAL unit after the start code at or after [at], and
/// the length of its start code; the length of the data when there is
/// none.
static size_t nextUnit(const uint8_t *data, size_t length, size_t at,
                       size_t *codeLength) {
  for (size_t i = at; i + 3 <= length; i++) {
    if (data[i] == 0 && data[i + 1] == 0 && data[i + 2] == 1) {
      *codeLength = 3;
      return i + 3;
    }
  }
  *codeLength = 0;
  return length;
}

EXPORT MmdVt *mmd_vt_open(void) {
  MmdVt *vt = calloc(1, sizeof(MmdVt));
  if (!vt) return NULL;
  pthread_mutex_init(&vt->lock, NULL);
  return vt;
}

/// Decodes one access unit; zero when VideoToolbox refused it or there
/// is no session yet.
EXPORT int32_t mmd_vt_decode(MmdVt *vt, const uint8_t *data, int32_t length) {
  // The NAL units other than the parameter sets and the delimiters, with
  // four-byte lengths: at most four bytes more per three-byte start code.
  uint8_t *sample = malloc((size_t)length + (size_t)length / 3 * 4 + 8);
  if (!sample) return 0;
  size_t sampleLength = 0;
  size_t code;
  size_t start = nextUnit(data, (size_t)length, 0, &code);
  while (start < (size_t)length) {
    size_t next = nextUnit(data, (size_t)length, start, &code);
    size_t end = next - code;
    // trailing zero bytes belong to the next start code
    while (code && end > start && data[end - 1] == 0) end--;
    if (end > start) {
      const uint8_t *nal = data + start;
      size_t size = end - start;
      int type = nal[0] & 0x1f;
      if (type == 7) {
        keep(vt, &vt->sps, &vt->spsLength, nal, size);
      } else if (type == 8) {
        keep(vt, &vt->pps, &vt->ppsLength, nal, size);
      } else if (type != 9) {
        sample[sampleLength++] = (uint8_t)(size >> 24);
        sample[sampleLength++] = (uint8_t)(size >> 16);
        sample[sampleLength++] = (uint8_t)(size >> 8);
        sample[sampleLength++] = (uint8_t)size;
        memcpy(sample + sampleLength, nal, size);
        sampleLength += size;
      }
    }
    start = next;
  }
  int ok = 0;
  if ((vt->changed || !vt->session) && !openSession(vt)) goto done;
  if (sampleLength == 0) {
    ok = 1;
    goto done;
  }
  CMBlockBufferRef block = NULL;
  if (CMBlockBufferCreateWithMemoryBlock(kCFAllocatorDefault, NULL,
                                         sampleLength, kCFAllocatorDefault,
                                         NULL, 0, sampleLength, 0,
                                         &block) != kCMBlockBufferNoErr) {
    goto done;
  }
  CMBlockBufferReplaceDataBytes(sample, block, 0, sampleLength);
  CMSampleTimingInfo timing = {CMTimeMake(1, 30), CMTimeMake(vt->time, 30),
                               kCMTimeInvalid};
  vt->time++;
  CMSampleBufferRef buffer = NULL;
  OSStatus status = CMSampleBufferCreateReady(
      kCFAllocatorDefault, block, vt->format, 1, 1, &timing, 1,
      &sampleLength, &buffer);
  CFRelease(block);
  if (status != noErr) goto done;
  // Synchronous, so that the pictures this unit finishes are out on
  // return; temporal processing lets the decoder put them in the order of
  // display.
  VTDecodeInfoFlags flags = 0;
  status = VTDecompressionSessionDecodeFrame(
      vt->session, buffer, kVTDecodeFrame_EnableTemporalProcessing, NULL,
      &flags);
  CFRelease(buffer);
  if (status == kVTInvalidSessionErr) {
    // The session is gone, as after the app went to the background on
    // iOS; the next unit makes a new one.
    closeSession(vt);
    goto done;
  }
  ok = status == noErr;
done:
  free(sample);
  return ok;
}

/// The size of the latest picture into [width] and [height]; zero when
/// there is none.
EXPORT int32_t mmd_vt_size(MmdVt *vt, int32_t *width, int32_t *height) {
  pthread_mutex_lock(&vt->lock);
  int has = vt->latest != NULL;
  if (has) {
    *width = (int32_t)CVPixelBufferGetWidth(vt->latest);
    *height = (int32_t)CVPixelBufferGetHeight(vt->latest);
  }
  pthread_mutex_unlock(&vt->lock);
  return has;
}

/// Copies the latest picture as RGBA into [rgba], which holds [capacity]
/// bytes, and drops it; zero when there is none or it does not fit.
EXPORT int32_t mmd_vt_take(MmdVt *vt, uint8_t *rgba, int32_t capacity) {
  pthread_mutex_lock(&vt->lock);
  CVPixelBufferRef image = vt->latest;
  vt->latest = NULL;
  pthread_mutex_unlock(&vt->lock);
  if (!image) return 0;
  int ok = 0;
  size_t width = CVPixelBufferGetWidth(image);
  size_t height = CVPixelBufferGetHeight(image);
  if ((size_t)capacity >= width * height * 4 &&
      CVPixelBufferLockBaseAddress(image, kCVPixelBufferLock_ReadOnly) ==
          kCVReturnSuccess) {
    const uint8_t *base = CVPixelBufferGetBaseAddress(image);
    size_t stride = CVPixelBufferGetBytesPerRow(image);
    for (size_t y = 0; y < height; y++) {
      const uint8_t *from = base + y * stride;
      uint8_t *to = rgba + y * width * 4;
      for (size_t x = 0; x < width; x++) {
        to[x * 4] = from[x * 4 + 2];
        to[x * 4 + 1] = from[x * 4 + 1];
        to[x * 4 + 2] = from[x * 4];
        to[x * 4 + 3] = 0xff;
      }
    }
    CVPixelBufferUnlockBaseAddress(image, kCVPixelBufferLock_ReadOnly);
    ok = 1;
  }
  CVPixelBufferRelease(image);
  return ok;
}

/// Drops the pictures in flight; the next unit makes a new session.
EXPORT void mmd_vt_flush(MmdVt *vt) {
  closeSession(vt);
  pthread_mutex_lock(&vt->lock);
  if (vt->latest) CVPixelBufferRelease(vt->latest);
  vt->latest = NULL;
  pthread_mutex_unlock(&vt->lock);
}

EXPORT void mmd_vt_close(MmdVt *vt) {
  mmd_vt_flush(vt);
  free(vt->sps);
  free(vt->pps);
  pthread_mutex_destroy(&vt->lock);
  free(vt);
}
