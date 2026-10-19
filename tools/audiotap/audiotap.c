/* audiotap — diagnostic for Wine's macOS audio output (DYLD_INSERT_LIBRARIES into a Wine process).
 * Wraps the render callback winecoreaudio installs and counts underruns: callbacks whose buffer ends in silence that
 * Wine padded because too little audio was queued (with a continuous test tone, exact zeros only come from padding).
 *   AUDIOTAP_LOG=<file>      stats written every 2 s: callbacks, frames per callback, underruns, padded frames
 *   AUDIOTAP_FRAMES=<n>      also set this process's device I/O buffer to n frames */
#include <AudioUnit/AudioUnit.h>
#include <CoreAudio/CoreAudio.h>
#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#define DYLD_INTERPOSE(_r, _o) __attribute__((used)) static struct { const void *r; const void *o; } _interpose_##_o \
    __attribute__((section("__DATA,__interpose"))) = { (const void *)(unsigned long)&_r, (const void *)(unsigned long)&_o };

typedef struct { AURenderCallback cb; void *ref; volatile long calls, frames, underruns, padded, last_n, primes; long hold; } Tap;
static long prime_frames(void) { const char *e = getenv("AUDIOTAP_PRIME_MS"); return e ? atol(e) : 0; }   /* ms, converted per call */
static Tap taps[8]; static int ntaps;

static OSStatus tap_cb(void *ref, AudioUnitRenderActionFlags *fl, const AudioTimeStamp *ts, UInt32 bus, UInt32 n, AudioBufferList *data) {
    Tap *t = ref;
    /* priming: macOS gets silence while the game's queue builds up (the game keeps writing one block per event) */
    if (t->hold > 0 && data && data->mNumberBuffers >= 1) {
        for (UInt32 b = 0; b < data->mNumberBuffers; b++) memset(data->mBuffers[b].mData, 0, data->mBuffers[b].mDataByteSize);
        t->hold -= n; t->calls++; t->last_n = n;
        return noErr;
    }
    OSStatus r = t->cb(t->ref, fl, ts, bus, n, data);
    if (data && data->mNumberBuffers >= 1 && data->mBuffers[0].mData) {
        const float *s = data->mBuffers[0].mData;
        UInt32 ch = data->mBuffers[0].mNumberChannels ? data->mBuffers[0].mNumberChannels : 1;
        UInt32 frames = data->mBuffers[0].mDataByteSize / (4 * ch), z = 0;
        while (z < frames) { UInt32 i = frames - 1 - z, c; for (c = 0; c < ch; c++) if (s[i * ch + c] != 0.0f) break; if (c < ch) break; z++; }
        int under = (z >= 16 && z < frames) || (z == frames && t->calls > 50);   /* shorter zero runs: the tone itself */
        if (under) {
            t->underruns++; t->padded += z;
            long pm = prime_frames();
            if (pm) { t->hold = pm * 96; t->primes++; }   /* frames at up to 96 kHz: ms × 96 */
        }
    }
    t->calls++; t->frames += n; t->last_n = n;
    return r;
}

static OSStatus my_set(AudioUnit u, AudioUnitPropertyID id, AudioUnitScope sc, AudioUnitElement el, const void *data, UInt32 size) {
    if (id == kAudioUnitProperty_SetRenderCallback && data && ntaps < 8) {
        const AURenderCallbackStruct *in = data;
        Tap *t = &taps[ntaps++]; t->cb = in->inputProc; t->ref = in->inputProcRefCon; t->hold = prime_frames() * 96;
        AURenderCallbackStruct mine = { tap_cb, t };
        const char *fr = getenv("AUDIOTAP_FRAMES");
        if (fr) { UInt32 f = (UInt32)atoi(fr); AudioUnitSetProperty(u, kAudioDevicePropertyBufferFrameSize, kAudioUnitScope_Global, 0, &f, sizeof f); }
        return AudioUnitSetProperty(u, id, sc, el, &mine, sizeof mine);
    }
    return AudioUnitSetProperty(u, id, sc, el, data, size);
}
DYLD_INTERPOSE(my_set, AudioUnitSetProperty)

static void *logger(void *p) {
    const char *path = p;
    for (;;) {
        sleep(2);
        if (!ntaps) continue;   /* only the process that plays audio writes (Wine starts several) */
        char fn[1024]; snprintf(fn, sizeof fn, "%s.%d", path, getpid());
        FILE *f = fopen(fn, "w"); if (!f) continue;
        for (int i = 0; i < ntaps; i++)
            fprintf(f, "stream%d calls=%ld frames_per_call=%ld underruns=%ld padded_frames=%ld primes=%ld\n", i, taps[i].calls, taps[i].last_n, taps[i].underruns, taps[i].padded, taps[i].primes);
        fclose(f);
    }
    return NULL;
}
__attribute__((constructor)) static void init(void) {
    const char *l = getenv("AUDIOTAP_LOG");
    if (l) { pthread_t th; pthread_create(&th, NULL, logger, (void *)l); pthread_detach(th); }
}
