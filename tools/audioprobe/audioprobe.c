/* audioprobe — what Skyrim's audio stack sees under Wine: creates XAudio2 2.7 through COM exactly like the game,
 * prints which xaudio2_7.dll answered (Microsoft's or Wine's) and the output device's channel layout.
 * Run it named SkyrimSE.exe so Wine's per-app DLL overrides apply. Build: tools/audioprobe/build.sh */
#define COBJMACROS
#include <windows.h>
#include <stdio.h>
#include <mmreg.h>

static const GUID CLSID_XAudio2_7 = {0x5a508685, 0xa254, 0x4fba, {0x9b, 0x82, 0x9a, 0x24, 0xb0, 0x03, 0x06, 0xaf}};
static const GUID IID_IXAudio2_7  = {0x8bcf1f58, 0x9fe7, 0x4583, {0x8a, 0xc6, 0xe2, 0xad, 0xc4, 0x65, 0xc8, 0xbb}};

typedef struct { WCHAR DeviceID[256]; WCHAR DisplayName[256]; UINT32 Role; WAVEFORMATEXTENSIBLE OutputFormat; } DEVICE_DETAILS;
typedef struct IXAudio27 IXAudio27;
typedef struct {   /* IXAudio2 (2.7, DirectX SDK June 2010) vtable, in order */
    HRESULT (WINAPI *QueryInterface)(IXAudio27 *, REFIID, void **);
    ULONG (WINAPI *AddRef)(IXAudio27 *);
    ULONG (WINAPI *Release)(IXAudio27 *);
    HRESULT (WINAPI *GetDeviceCount)(IXAudio27 *, UINT32 *);
    HRESULT (WINAPI *GetDeviceDetails)(IXAudio27 *, UINT32, DEVICE_DETAILS *);
    HRESULT (WINAPI *Initialize)(IXAudio27 *, UINT32, UINT32);
    HRESULT (WINAPI *RegisterForCallbacks)(IXAudio27 *, void *);
    void (WINAPI *UnregisterForCallbacks)(IXAudio27 *, void *);
    HRESULT (WINAPI *CreateSourceVoice)(IXAudio27 *, void **, const WAVEFORMATEX *, UINT32, float, void *, const void *, const void *);
    HRESULT (WINAPI *CreateSubmixVoice)(IXAudio27 *, void **, UINT32, UINT32, UINT32, UINT32, const void *, const void *);
    HRESULT (WINAPI *CreateMasteringVoice)(IXAudio27 *, void **, UINT32, UINT32, UINT32, UINT32, const void *);
    HRESULT (WINAPI *StartEngine)(IXAudio27 *);
    void (WINAPI *StopEngine)(IXAudio27 *);
    HRESULT (WINAPI *CommitChanges)(IXAudio27 *, UINT32);
    void (WINAPI *GetPerformanceData)(IXAudio27 *, void *);
} IXAudio27Vtbl;
typedef struct { UINT64 audioCycles, totalCycles; UINT32 minCycles, maxCycles, memory, latencySamples, glitches, activeSources, totalSources, rest[8]; } PERF;
typedef struct { UINT32 Flags, AudioBytes; const BYTE *pAudioData; UINT32 PlayBegin, PlayLength, LoopBegin, LoopLength, LoopCount; void *pContext; } XA_BUFFER;
/* IXAudio2SourceVoice: 19 IXAudio2Voice methods (… SetVolume = 12 …), then Start = 19, Stop = 20, SubmitSourceBuffer = 21 */
typedef HRESULT (WINAPI *SetVolumeFn)(void *, float, UINT32);
typedef HRESULT (WINAPI *StartFn)(void *, UINT32, UINT32);
typedef HRESULT (WINAPI *SubmitFn)(void *, const XA_BUFFER *, const void *);
#define VFN(v, i) ((*(void ***)(v))[i])
struct IXAudio27 { const IXAudio27Vtbl *lpVtbl; };

static void company(HMODULE m, char *out, int n)
{
    out[0] = 0;
    HRSRC r = FindResourceW(m, MAKEINTRESOURCEW(1), (LPCWSTR)RT_VERSION);
    if (!r) { snprintf(out, n, "(no version resource)"); return; }
    void *p = LockResource(LoadResource(m, r)); DWORD sz = SizeofResource(m, r);
    void *copy = malloc(sz * 2); memcpy(copy, p, sz);
    WCHAR *v = NULL; UINT len = 0;
    if (VerQueryValueW(copy, L"\\StringFileInfo\\040904B0\\CompanyName", (void **)&v, &len) ||
        VerQueryValueW(copy, L"\\StringFileInfo\\040904E4\\CompanyName", (void **)&v, &len)) WideCharToMultiByte(CP_UTF8, 0, v, -1, out, n, NULL, NULL);
    else snprintf(out, n, "(no CompanyName)");
    free(copy);
}

int main(void)
{
    CoInitializeEx(NULL, COINIT_MULTITHREADED);
    IXAudio27 *xa = NULL;
    HRESULT hr = CoCreateInstance(&CLSID_XAudio2_7, NULL, CLSCTX_INPROC_SERVER, &IID_IXAudio2_7, (void **)&xa);
    if (FAILED(hr) || !xa) { printf("create=FAIL 0x%08lx\n", hr); return 1; }
    HMODULE m = GetModuleHandleW(L"xaudio2_7.dll");
    char co[128]; company(m, co, sizeof co);
    printf("xaudio2_7=%s\n", co);
    UINT32 n = 0; xa->lpVtbl->GetDeviceCount(xa, &n);
    printf("devices=%u\n", n);
    for (UINT32 i = 0; i < n; i++) {
        DEVICE_DETAILS d; memset(&d, 0, sizeof d);
        if (SUCCEEDED(xa->lpVtbl->GetDeviceDetails(xa, i, &d))) {
            char name[256]; WideCharToMultiByte(CP_UTF8, 0, d.DisplayName, -1, name, sizeof name, NULL, NULL);
            printf("device%u=%s channels=%u mask=0x%lx rate=%lu role=%u\n", i, name, d.OutputFormat.Format.nChannels,
                   d.OutputFormat.dwChannelMask, d.OutputFormat.Format.nSamplesPerSec, d.Role);
        }
    }
    hr = xa->lpVtbl->Initialize(xa, 0, 1 /* XAUDIO2_DEFAULT_PROCESSOR */);
    printf("initialize=0x%08lx\n", hr);
    /* play a muted 1 s loop for N seconds (like the game: 16 voices) and read XAudio2's own glitch counter */
    void *master = NULL;
    hr = xa->lpVtbl->CreateMasteringVoice(xa, &master, 0, 0, 0, 0, NULL);
    printf("mastering=0x%08lx\n", hr);
    static short pcm[48000 * 2];
    for (int i = 0; i < 48000; i++) pcm[2 * i] = pcm[2 * i + 1] = (short)(3000 * ((i / 55) % 2 ? 1 : -1));
    WAVEFORMATEX wf = { WAVE_FORMAT_PCM, 2, 48000, 48000 * 4, 4, 16, 0 };
    XA_BUFFER b = { 0, sizeof pcm, (const BYTE *)pcm, 0, 0, 0, 0, 255 /* XAUDIO2_LOOP_INFINITE */, NULL };
    for (int v = 0; v < 16; v++) {
        void *src = NULL;
        if (FAILED(xa->lpVtbl->CreateSourceVoice(xa, &src, &wf, 0, 2.0f, NULL, NULL, NULL)) || !src) break;
        float vol = 0.0f; char *pv = getenv("PROBE_VOLUME"); if (pv) vol = (float)atof(pv);   /* audible test tone for tools/audiotap */
        ((SetVolumeFn)VFN(src, 12))(src, vol, 0);
        ((SubmitFn)VFN(src, 21))(src, &b, NULL);
        ((StartFn)VFN(src, 19))(src, 0, 0);
    }
    xa->lpVtbl->StartEngine(xa);
    int secs = 10; char *e = getenv("PROBE_SECONDS"); if (e) secs = atoi(e);
    Sleep(secs * 1000);
    PERF pd; memset(&pd, 0, sizeof pd);
    xa->lpVtbl->GetPerformanceData(xa, &pd);
    printf("glitches=%u latency_samples=%u active_voices=%u max_cycles_per_quantum=%u\n", pd.glitches, pd.latencySamples, pd.activeSources, pd.maxCycles);
    HMODULE x3 = LoadLibraryW(L"x3daudio1_7.dll");
    if (x3) { company(x3, co, sizeof co); printf("x3daudio1_7=%s\n", co); }
    xa->lpVtbl->Release(xa);
    return 0;
}
