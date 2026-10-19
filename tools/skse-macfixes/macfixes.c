/* SkyrimMT_MacFixes — SKSE plugin (x86_64 mingw) deployed by SkyrimMT into every profile. Works around Wine behaviour
 * that differs from Windows; touches no game memory or structures (loads on every SE/AE version).
 *
 * Mouse pointer: Skyrim acquires the mouse with DirectInput (exclusive) on worker threads. Windows then hides the
 * system pointer over the game; Wine only lowers the ShowCursor count of the calling thread, so the window's own
 * thread keeps showing the arrow and macOS draws it on top of Skyrim's menu cursor. Fix: subclass the game window
 * and answer WM_SETCURSOR with no cursor while the game window is in the foreground (Skyrim always draws its own).
 *
 * Subclassing uses the window's own character set (IsWindowUnicode): mixing A and W makes Wine hand out 0xFFFF____
 * stand-in handles for the previous window procedure, and other plugins in the chain (ImprovedCameraSE, AltTabFix,
 * detection meters…) then crashed calling one (crash log 2026-10-18: CallWindowProc → 0xFFFF002B on Alt).
 *
 * Build: tools/skse-macfixes/build.sh → build/skse/SkyrimMT_MacFixes.dll
 */
#include <windows.h>
#include <stdint.h>
#include <string.h>

/* skse64 PluginAPI.h (SKSE 2.2.x): SKSEPluginVersionData, exported as SKSEPlugin_Version (AE) */
typedef struct {
    uint32_t dataVersion;          /* 1 */
    uint32_t pluginVersion;
    char name[256];
    char author[256];
    char supportEmail[252];
    uint32_t versionIndependenceEx;  /* kVersionIndependentEx_NoStructUse = 1 */
    uint32_t versionIndependence;    /* kVersionIndependent_Signatures = 2 */
    uint32_t compatibleVersions[16];
    uint32_t seVersionRequired;
} SKSEPluginVersionData;

/* PluginInfo for the pre-AE loader (SKSE 2.0.x on 1.5.97) */
typedef struct { uint32_t infoVersion; const char *name; uint32_t version; } PluginInfo;

__declspec(dllexport) SKSEPluginVersionData SKSEPlugin_Version = {
    1, 1, "SkyrimMT Mac Fixes", "SkyrimMT", "", 1, 2, {0}, 0
};

static HWND g_game;
static WNDPROC g_orig;
static BOOL g_unicode;

static LRESULT CALLBACK game_proc(HWND hwnd, UINT msg, WPARAM wp, LPARAM lp)
{
    if (msg == WM_SETCURSOR && LOWORD(lp) == HTCLIENT && GetForegroundWindow() == hwnd) {
        SetCursor(NULL);
        return TRUE;
    }
    return g_unicode ? CallWindowProcW(g_orig, hwnd, msg, wp, lp) : CallWindowProcA(g_orig, hwnd, msg, wp, lp);
}

static BOOL CALLBACK find_game(HWND hwnd, LPARAM lp)
{
    DWORD pid = 0;
    wchar_t cls[64];
    GetWindowThreadProcessId(hwnd, &pid);
    if (pid != GetCurrentProcessId() || !IsWindowVisible(hwnd)) return TRUE;
    if (GetClassNameW(hwnd, cls, 64) && wcscmp(cls, L"Skyrim Special Edition") == 0) { *(HWND *)lp = hwnd; return FALSE; }
    return TRUE;
}

static DWORD WINAPI watch(LPVOID unused)
{
    (void)unused;
    for (int i = 0; i < 600 && !g_game; i++) {   /* the window appears a few seconds after the plugin loads */
        HWND w = NULL;
        EnumWindows(find_game, (LPARAM)&w);
        if (w) {
            g_unicode = IsWindowUnicode(w);
            g_orig = g_unicode ? (WNDPROC)SetWindowLongPtrW(w, GWLP_WNDPROC, (LONG_PTR)game_proc)
                               : (WNDPROC)SetWindowLongPtrA(w, GWLP_WNDPROC, (LONG_PTR)game_proc);
            g_game = w;
            /* apply now, from the window's own thread, instead of waiting for the next mouse move */
            SendMessageTimeoutW(w, WM_SETCURSOR, (WPARAM)w, MAKELPARAM(HTCLIENT, WM_MOUSEMOVE), SMTO_ABORTIFHUNG, 1000, NULL);
            break;
        }
        Sleep(500);
    }
    return 0;
}

static void start(void)
{
    HANDLE t = CreateThread(NULL, 0, watch, NULL, 0, NULL);
    if (t) CloseHandle(t);
}

__declspec(dllexport) BOOL SKSEPlugin_Query(const void *skse, PluginInfo *info)
{
    (void)skse;
    info->infoVersion = 1; info->name = "SkyrimMT Mac Fixes"; info->version = 1;
    return TRUE;
}

__declspec(dllexport) BOOL SKSEPlugin_Load(const void *skse)
{
    (void)skse;
    start();
    return TRUE;
}

BOOL WINAPI DllMain(HINSTANCE h, DWORD reason, LPVOID r) { (void)h; (void)reason; (void)r; return TRUE; }
