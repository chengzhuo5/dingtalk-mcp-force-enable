// dtinject21.cpp - attempt to start the MCP server directly.
//   (a) patch the flag check site 0x57A0F4D (74 0B -> 90 90) so any future pass
//       through that routine starts the server;
//   (b) invoke the start routine at moduleOffset 0x57AB2B0 with port 0x1F9A (8090),
//       which the original code passes in ecx.
#define WIN32_LEAN_AND_MEAN
#include <winsock2.h>
#include <ws2tcpip.h>
#include <windows.h>
#include <stdio.h>
#include <stdarg.h>
#include <string.h>
#include <excpt.h>

static char g_logPath[MAX_PATH] = {0};
static CRITICAL_SECTION g_logLock;

static void LogInit(void) {
    HMODULE self = NULL;
    GetModuleHandleExA(GET_MODULE_HANDLE_EX_FLAG_FROM_ADDRESS |
                       GET_MODULE_HANDLE_EX_FLAG_UNCHANGED_REFCOUNT,
                       (LPCSTR)&LogInit, &self);
    char mod[MAX_PATH] = {0};
    if (self) GetModuleFileNameA(self, mod, MAX_PATH);
    char* slash = strrchr(mod, '\\');
    if (slash) *(slash + 1) = 0;
    _snprintf_s(g_logPath, MAX_PATH, _TRUNCATE, "%sprobe21.log", mod);
    InitializeCriticalSection(&g_logLock);
}

static void Log(const char* fmt, ...) {
    if (!g_logPath[0]) return;
    EnterCriticalSection(&g_logLock);
    FILE* f = fopen(g_logPath, "a");
    if (f) {
        SYSTEMTIME st; GetLocalTime(&st);
        fprintf(f, "[%02d:%02d:%02d.%03d] ", st.wHour, st.wMinute, st.wSecond, st.wMilliseconds);
        va_list ap; va_start(ap, fmt);
        vfprintf(f, fmt, ap);
        va_end(ap);
        fprintf(f, "\n");
        fclose(f);
    }
    LeaveCriticalSection(&g_logLock);
}

static DWORD_PTR g_modBase = 0;

static BOOL PortListening(int port) {
    WSADATA wsa;
    if (WSAStartup(MAKEWORD(2, 2), &wsa) != 0) return FALSE;
    SOCKET s = socket(AF_INET, SOCK_STREAM, IPPROTO_TCP);
    BOOL ok = FALSE;
    if (s != INVALID_SOCKET) {
        sockaddr_in a;
        memset(&a, 0, sizeof(a));
        a.sin_family = AF_INET;
        a.sin_port = htons((u_short)port);
        a.sin_addr.s_addr = inet_addr("127.0.0.1");
        if (connect(s, (sockaddr*)&a, sizeof(a)) == 0) ok = TRUE;
        closesocket(s);
    }
    WSACleanup();
    return ok;
}

typedef int (__cdecl *fn_start_t)(int port);

static DWORD WINAPI Worker(LPVOID) {
    Log("=== probe21 MCP start attempt (pid=%lu) ===", GetCurrentProcessId());
    HMODULE mf = NULL;
    for (int i = 0; i < 40 && !mf; i++) { mf = GetModuleHandleA("MainFrame.dll"); if (!mf) Sleep(500); }
    if (!mf) { Log("MainFrame.dll missing"); return 0; }
    g_modBase = (DWORD_PTR)mf;
    Log("MainFrame.dll base=0x%p", (void*)g_modBase);

    Log("port 8090 listening BEFORE: %s", PortListening(8090) ? "YES" : "no");

    // ---- (a) patch the conditional skip so the start call always runs -----
    BYTE* patchSite = (BYTE*)(g_modBase + 0x57A0F4D);
    BYTE before[2] = {0};
    __try { before[0] = patchSite[0]; before[1] = patchSite[1]; } __except (EXCEPTION_EXECUTE_HANDLER) {}
    Log("patch site 0x57A0F4D bytes before: %02X %02X (expected 74 0B = jz)", before[0], before[1]);

    if (before[0] == 0x74 && before[1] == 0x0B) {
        DWORD old = 0;
        if (VirtualProtect(patchSite, 2, PAGE_EXECUTE_READWRITE, &old)) {
            patchSite[0] = 0x90;   // nop
            patchSite[1] = 0x90;   // nop
            DWORD tmp = 0;
            VirtualProtect(patchSite, 2, old, &tmp);
            FlushInstructionCache(GetCurrentProcess(), patchSite, 2);
            Log("PATCHED 0x57A0F4D: 74 0B -> 90 90 (conditional skip removed)");
        } else {
            Log("VirtualProtect failed: %lu", GetLastError());
        }
    } else {
        Log("patch site does not look like jz 0x0B, leaving untouched");
    }

    // ---- (b) call the start routine directly with the original port ------
    DWORD_PTR startAddr = g_modBase + 0x57AB2B0;
    fn_start_t startFn = (fn_start_t)startAddr;
    Log("calling start routine at 0x%p with port 0x1F9A (8090)", (void*)startAddr);

    int rc = -1;
    __try {
        rc = startFn(0x1F9A);
        Log("start routine returned %d", rc);
    }
    __except (EXCEPTION_EXECUTE_HANDLER) {
        Log("start routine EXC 0x%08X", GetExceptionCode());
    }

    Sleep(2500);
    Log("port 8090 listening AFTER: %s", PortListening(8090) ? "YES" : "no");

    // also probe the neighbouring start routine used by the other call site
    DWORD_PTR altAddr = g_modBase + 0x57AB070;
    fn_start_t altFn = (fn_start_t)altAddr;
    Log("trying alternative routine at 0x%p", (void*)altAddr);
    __try {
        int rc2 = altFn(0x1F9A);
        Log("alt routine returned %d", rc2);
    }
    __except (EXCEPTION_EXECUTE_HANDLER) {
        Log("alt routine EXC 0x%08X", GetExceptionCode());
    }
    Sleep(2000);
    Log("port 8090 listening FINAL: %s", PortListening(8090) ? "YES" : "no");

    Log("=== probe21 done ===");
    return 0;
}

BOOL WINAPI DllMain(HINSTANCE hInst, DWORD reason, LPVOID) {
    if (reason == DLL_PROCESS_ATTACH) {
        DisableThreadLibraryCalls(hInst);
        LogInit();
        HANDLE t = CreateThread(NULL, 0, Worker, NULL, 0, NULL);
        if (t) CloseHandle(t);
    }
    return TRUE;
}
