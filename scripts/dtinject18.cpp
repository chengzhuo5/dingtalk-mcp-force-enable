// dtinject18.cpp - locate code that references the MCP server strings inside MainFrame.dll.
// Strategy: find the string VA in the module image, then scan executable regions for
// RIP-relative references (lea reg,[rip+disp32]) pointing at it. Those sites are the
// MCP start-up logic / flag checks.
#define WIN32_LEAN_AND_MEAN
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
    _snprintf_s(g_logPath, MAX_PATH, _TRUNCATE, "%sprobe18.log", mod);
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
static DWORD_PTR g_modEnd = 0;

static BYTE* FindInRegion(BYTE* start, BYTE* end, const char* needle, int nlen) {
    if ((DWORD_PTR)end <= (DWORD_PTR)start || (end - start) < nlen) return NULL;
    BYTE* p = start;
    BYTE* limit = end - nlen;
    while (p < limit) {
        int ok = 0;
        __try { ok = (memcmp(p, needle, nlen) == 0); }
        __except (EXCEPTION_EXECUTE_HANDLER) { return NULL; }
        if (ok) return p;
        p++;
    }
    return NULL;
}

static int g_totalRefs = 0;

static BYTE* FindStringAnywhere(const char* needle) {
    int nlen = (int)strlen(needle);
    BYTE* p = (BYTE*)g_modBase;
    while ((DWORD_PTR)p < g_modEnd) {
        MEMORY_BASIC_INFORMATION mbi;
        if (VirtualQuery(p, &mbi, sizeof(mbi)) == 0) break;
        BYTE* base = (BYTE*)mbi.BaseAddress;
        SIZE_T rsize = mbi.RegionSize;
        DWORD prot = mbi.Protect & 0xFF;
        BOOL readable = (mbi.State == MEM_COMMIT) && prot != PAGE_NOACCESS && prot != PAGE_GUARD &&
                        (prot == PAGE_READONLY || prot == PAGE_READWRITE || prot == PAGE_EXECUTE_READ ||
                         prot == PAGE_EXECUTE_READWRITE || prot == PAGE_WRITECOPY || prot == PAGE_EXECUTE_WRITECOPY);
        if (readable && (DWORD_PTR)base >= g_modBase && (DWORD_PTR)base < g_modEnd) {
            BYTE* r = FindInRegion(base, base + rsize, needle, nlen);
            if (r) return r;
        }
        p = base + rsize;
    }
    return NULL;
}

// scan executable regions of the module for rip-relative refs to |target|
static void ScanRefs(BYTE* target, const char* label, int maxReport) {
    DWORD_PTR t = (DWORD_PTR)target;
    BYTE* p = (BYTE*)g_modBase;
    int reported = 0;

    while ((DWORD_PTR)p < g_modEnd && reported < maxReport) {
        MEMORY_BASIC_INFORMATION mbi;
        if (VirtualQuery(p, &mbi, sizeof(mbi)) == 0) break;
        BYTE* base = (BYTE*)mbi.BaseAddress;
        SIZE_T rsize = mbi.RegionSize;
        DWORD prot = mbi.Protect & 0xFF;

        BOOL exec = (mbi.State == MEM_COMMIT) &&
                    (prot == PAGE_EXECUTE_READ || prot == PAGE_EXECUTE_READWRITE ||
                     prot == PAGE_EXECUTE_WRITECOPY || prot == PAGE_EXECUTE);

        if (exec && (DWORD_PTR)base >= g_modBase && (DWORD_PTR)base < g_modEnd) {
            BYTE* q = base;
            BYTE* limit = base + rsize - 8;
            while (q < limit && reported < maxReport) {
                DWORD disp = 0;
                int ok = 0;
                __try { disp = *(DWORD*)q; } __except (EXCEPTION_EXECUTE_HANDLER) { break; }
                if (disp != 0) {
                    DWORD_PTR addr = (DWORD_PTR)q + 4;      // rip after the disp field
                    DWORD_PTR tgt  = addr + (LONG)disp;
                    if (tgt == t) {
                        reported++;
                        g_totalRefs++;
                        // the instruction usually starts a few bytes before the disp
                        Log("  [%s] ref at 0x%p (moduleOffset=0x%llX) instr~0x%p bytes=%02X %02X %02X %02X %02X %02X",
                            label, q, (unsigned long long)((DWORD_PTR)q - g_modBase),
                            (void*)((DWORD_PTR)q - 4),
                            ((BYTE*)((DWORD_PTR)q - 4))[0], ((BYTE*)((DWORD_PTR)q - 4))[1],
                            ((BYTE*)((DWORD_PTR)q - 4))[2], ((BYTE*)((DWORD_PTR)q - 4))[3],
                            ((BYTE*)((DWORD_PTR)q - 4))[4], ((BYTE*)((DWORD_PTR)q - 4))[5]);
                    }
                }
                q++;
            }
        }
        p = base + rsize;
    }
    Log("[%s] refs found: %d", label, reported);
    Log("");
}

static DWORD WINAPI Worker(LPVOID) {
    Log("=== probe18 MCP code reference scan (pid=%lu) ===", GetCurrentProcessId());

    HMODULE mf = NULL;
    for (int i = 0; i < 40 && !mf; i++) {
        mf = GetModuleHandleA("MainFrame.dll");
        if (!mf) Sleep(500);
    }
    if (!mf) { Log("MainFrame.dll not loaded"); return 0; }
    g_modBase = (DWORD_PTR)mf;

    // image size from PE headers
    __try {
        IMAGE_DOS_HEADER* dos = (IMAGE_DOS_HEADER*)mf;
        IMAGE_NT_HEADERS* nt = (IMAGE_NT_HEADERS*)((BYTE*)mf + dos->e_lfanew);
        g_modEnd = g_modBase + nt->OptionalHeader.SizeOfImage;
    } __except (EXCEPTION_EXECUTE_HANDLER) { g_modEnd = g_modBase + 0xA000000ULL; }
    Log("MainFrame.dll base=0x%p end=0x%p size=0x%llX",
        (void*)g_modBase, (void*)g_modEnd, (unsigned long long)(g_modEnd - g_modBase));

    struct { const char* s; const char* label; int max; } targets[] = {
        { "Starting MCP server...",                       "STARTLOG",  8 },
        { "DingTalkMcpServer started successfully on port ", "DTSTART", 8 },
        { "DingTalk Integrated MCP Server",               "BANNER",    8 },
        { "SendMessageTool",                              "SENDTOOL",  8 },
        { "MCP server builder was not initialized.",      "NOBUILDER", 8 },
    };

    for (int i = 0; i < (int)(sizeof(targets) / sizeof(targets[0])); i++) {
        BYTE* sp = FindStringAnywhere(targets[i].s);
        if (!sp) { Log("[%s] string not found: %s", targets[i].label, targets[i].s); Log(""); continue; }
        Log("[%s] string @0x%p (moduleOffset=0x%llX) \"%s\"",
            targets[i].label, sp, (unsigned long long)((DWORD_PTR)sp - g_modBase), targets[i].s);
        ScanRefs(sp, targets[i].label, targets[i].max);
    }

    Log("total refs: %d", g_totalRefs);
    Log("=== probe18 done ===");
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
