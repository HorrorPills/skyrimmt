/* frametrace — proxy d3d11.dll that timestamps IDXGISwapChain::Present and writes a CSV, forwarding everything to
 * the real D3D11 (DXMT's builtin d3d11.dll, loaded from system32). Dev/bench tool (PLAN §7), x86_64 mingw.
 *
 * Install: copy build/frametrace/d3d11.dll next to SkyrimSE.exe and launch with WINEDLLOVERRIDES="d3d11=n,b"
 * (per launch, no registry change). Without the override the file is ignored (builtin d3d11 wins).
 * Output: $FRAMETRACE_OUT (Windows or unix path, default .\frametrace.csv), columns:
 *   frame, t_us (QPC at Present entry since first frame), dt_us (interval to previous Present entry),
 *   present_us (time spent inside Present: vsync/back-pressure wait + DXMT submit), sync (SyncInterval argument)
 */
#define COBJMACROS
#include <windows.h>
#include <d3d11.h>
#include <dxgi.h>
#include <stdio.h>

typedef HRESULT (WINAPI *PFN_CREATE_DEV_SC)(IDXGIAdapter *, D3D_DRIVER_TYPE, HMODULE, UINT, const D3D_FEATURE_LEVEL *,
    UINT, UINT, const DXGI_SWAP_CHAIN_DESC *, IDXGISwapChain **, ID3D11Device **, D3D_FEATURE_LEVEL *, ID3D11DeviceContext **);
typedef HRESULT (WINAPI *PFN_CREATE_DEV)(IDXGIAdapter *, D3D_DRIVER_TYPE, HMODULE, UINT, const D3D_FEATURE_LEVEL *,
    UINT, UINT, ID3D11Device **, D3D_FEATURE_LEVEL *, ID3D11DeviceContext **);
typedef HRESULT (WINAPI *PFN_PRESENT)(IDXGISwapChain *, UINT, UINT);

static HMODULE real;
static PFN_PRESENT real_present;
static FILE *out;
static LARGE_INTEGER freq, first, prev;
static unsigned long long frames;
static CRITICAL_SECTION lock;

static HMODULE load_real(void)
{
    if (!real) {
        char path[MAX_PATH];
        GetSystemDirectoryA(path, sizeof(path));
        lstrcatA(path, "\\d3d11.dll");
        real = LoadLibraryA(path);
    }
    return real;
}

static void open_out(void)
{
    const char *p = getenv("FRAMETRACE_OUT");
    out = fopen(p && *p ? p : "frametrace.csv", "w");
    if (out) { setvbuf(out, NULL, _IOFBF, 1 << 16); fprintf(out, "frame,t_us,dt_us,present_us,sync\n"); }
}

static HRESULT WINAPI hook_present(IDXGISwapChain *sc, UINT sync, UINT flags)
{
    LARGE_INTEGER a, b;
    QueryPerformanceCounter(&a);
    HRESULT hr = real_present(sc, sync, flags);
    QueryPerformanceCounter(&b);
    EnterCriticalSection(&lock);
    if (!frames) first = prev = a;
    if (out) {
        fprintf(out, "%llu,%lld,%lld,%lld,%u\n", frames,
                (a.QuadPart - first.QuadPart) * 1000000 / freq.QuadPart,
                (a.QuadPart - prev.QuadPart) * 1000000 / freq.QuadPart,
                (b.QuadPart - a.QuadPart) * 1000000 / freq.QuadPart, sync);
        if ((frames & 255) == 255) fflush(out);
    }
    prev = a; frames++;
    LeaveCriticalSection(&lock);
    return hr;
}

static void hook_swapchain(IDXGISwapChain *sc)
{
    void **vt = *(void ***)sc;
    if (vt[8] == (void *)hook_present) return;       /* IDXGISwapChain::Present = slot 8 */
    DWORD old;
    real_present = (PFN_PRESENT)vt[8];
    if (VirtualProtect(&vt[8], sizeof(void *), PAGE_EXECUTE_READWRITE, &old)) {
        vt[8] = (void *)hook_present;
        VirtualProtect(&vt[8], sizeof(void *), old, &old);
    }
}

__declspec(dllexport) HRESULT WINAPI D3D11CreateDeviceAndSwapChain(IDXGIAdapter *ad, D3D_DRIVER_TYPE dt, HMODULE sw,
    UINT fl, const D3D_FEATURE_LEVEL *lv, UINT nlv, UINT sdk, const DXGI_SWAP_CHAIN_DESC *desc, IDXGISwapChain **sc,
    ID3D11Device **dev, D3D_FEATURE_LEVEL *got, ID3D11DeviceContext **ctx)
{
    PFN_CREATE_DEV_SC f = load_real() ? (PFN_CREATE_DEV_SC)GetProcAddress(real, "D3D11CreateDeviceAndSwapChain") : NULL;
    if (!f) return E_FAIL;
    HRESULT hr = f(ad, dt, sw, fl, lv, nlv, sdk, desc, sc, dev, got, ctx);
    if (SUCCEEDED(hr) && sc && *sc) hook_swapchain(*sc);
    return hr;
}

__declspec(dllexport) HRESULT WINAPI D3D11CreateDevice(IDXGIAdapter *ad, D3D_DRIVER_TYPE dt, HMODULE sw, UINT fl,
    const D3D_FEATURE_LEVEL *lv, UINT nlv, UINT sdk, ID3D11Device **dev, D3D_FEATURE_LEVEL *got, ID3D11DeviceContext **ctx)
{
    PFN_CREATE_DEV f = load_real() ? (PFN_CREATE_DEV)GetProcAddress(real, "D3D11CreateDevice") : NULL;
    return f ? f(ad, dt, sw, fl, lv, nlv, sdk, dev, got, ctx) : E_FAIL;
}

/* rarely used entry points: forwarded with a generic trampoline (same signature in the real DLL) */
#define FWD(name) \
    __declspec(dllexport) void *name(void *a, void *b, void *c, void *d, void *e, void *f, void *g, void *h, void *i, void *j) { \
        typedef void *(*fn)(void *, void *, void *, void *, void *, void *, void *, void *, void *, void *); \
        fn p = load_real() ? (fn)GetProcAddress(real, #name) : NULL; \
        return p ? p(a, b, c, d, e, f, g, h, i, j) : (void *)(LONG_PTR)E_FAIL; }
FWD(D3D11CoreCreateDevice)
FWD(D3D11On12CreateDevice)

BOOL WINAPI DllMain(HINSTANCE inst, DWORD reason, void *reserved)
{
    if (reason == DLL_PROCESS_ATTACH) {
        DisableThreadLibraryCalls(inst);
        InitializeCriticalSection(&lock);
        QueryPerformanceFrequency(&freq);
        open_out();
    } else if (reason == DLL_PROCESS_DETACH && out) {
        fflush(out); fclose(out);
    }
    return TRUE;
}
