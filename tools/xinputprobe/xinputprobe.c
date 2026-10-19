/* xinputprobe — what Skyrim's XInput sees inside the Wine prefix (x86_64 mingw). Skyrim SE uses xinput1_3.dll.
 * Prints one line per slot: "slot <n> connected <subtype> <flags>" or "slot <n> none". Used by the launcher's
 * Controllers row ("seen by Skyrim"). Build: tools/xinputprobe/build.sh */
#include <windows.h>
#include <stdio.h>

typedef struct { WORD wButtons; BYTE bLeftTrigger, bRightTrigger; SHORT sThumbLX, sThumbLY, sThumbRX, sThumbRY; } GAMEPAD;
typedef struct { DWORD dwPacketNumber; GAMEPAD Gamepad; } STATE;
typedef struct { BYTE Type, SubType; WORD Flags; GAMEPAD Gamepad; struct { WORD l, r; } Vibration; } CAPS;
typedef DWORD (WINAPI *GetState)(DWORD, STATE *);
typedef DWORD (WINAPI *GetCaps)(DWORD, DWORD, CAPS *);

int main(void)
{
    HMODULE x = LoadLibraryA("xinput1_3.dll");
    if (!x) { printf("error no xinput1_3\n"); return 2; }
    GetState gs = (GetState)GetProcAddress(x, "XInputGetState");
    GetCaps gc = (GetCaps)GetProcAddress(x, "XInputGetCapabilities");
    Sleep(1500);   /* winebus enumerates devices shortly after the first XInput use */
    for (DWORD i = 0; i < 4; i++) {
        STATE s; CAPS c;
        if (gs(i, &s) == ERROR_SUCCESS) {
            BYTE sub = (gc && gc(i, 0, &c) == ERROR_SUCCESS) ? c.SubType : 0;
            printf("slot %lu connected %u\n", i + 1, sub);
        } else printf("slot %lu none\n", i + 1);
    }
    fflush(stdout);
    return 0;
}
