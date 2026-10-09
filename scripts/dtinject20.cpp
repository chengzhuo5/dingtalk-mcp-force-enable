// dtinject20.cpp - dump the code around the MCP start call site (moduleOffset
// 0x57A0F54) to find the enable_mcp_server check, plus the function entry before it.
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
    _snprintf_s(g_logPath, MAX_PATH, _TRUNCATE, "%sprobe20.log", mod);
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

static void DumpCode(DWORD_PTR fromOff, DWORD_PTR toOff, const char* tag) {
    Log("--- %s: module offsets 0x%llX .. 0x%llX ---", tag,
        (unsigned long long)fromOff, (unsigned long long)toOff);
    for (DWORD_PTR off = fromOff; off < toOff; off += 16) {
        BYTE b[16];
        int ok = 1;
        __try { memcpy(b, (void*)(g_modBase + off), 16); }
        __except (EXCEPTION_EXECUTE_HANDLER) { ok = 0; }
        if (!ok) { Log("  %08llX: <unreadable>", (unsigned long long)off); continue; }
        char hex[60] = {0};
        int ci = 0;
        for (int i = 0; i < 16; i++) ci += _snprintf_s(hex + ci, sizeof(hex) - ci, _TRUNCATE, "%02X ", b[i]);
        Log("  %08llX: %s", (unsigned long long)off, hex);
    }
    Log("");
}

static void FindFuncEntry(DWORD_PTR from, DWORD_PTR backLimit) {
    Log("--- scanning backwards from 0x%llX for function entry ---", (unsigned long long)from);
    for (DWORD_PTR off = from; off > backLimit; off--) {
        BYTE v = 0, prev = 0;
        __try {
            v = *(BYTE*)(g_modBase + off);
            prev = *(BYTE*)(g_modBase + off - 1);
        } __except (EXCEPTION_EXECUTE_HANDLER) { break; }
        if (prev == 0xCC && v != 0xCC) {
            Log("  likely entry at 0x%llX (after int3 padding)", (unsigned long long)off);
            DumpCode(off, off + 96, "entry head");
        }
    }
    Log("");
}

// find all call/jmp rel32 targets inside the MCP region from anywhere
static void FindAllCallsInto(DWORD_PTR lo, DWORD_PTR hi) {
    Log("--- all calls/jmps into 0x%llX..0x%llX ---",
        (unsigned long long)(lo - g_modBase), (unsigned long long)(hi - g_modBase));
    int reported = 0;
    BYTE* p = (BYTE*)g_modBase;
    DWORD_PTR end = g_modBase + 0x9450000ULL;
    while ((DWORD_PTR)p < end && reported < 60) {
        MEMORY_BASIC_INFORMATION mbi;
        if (VirtualQuery(p, &mbi, sizeof(mbi)) == 0) break;
        BYTE* base = (BYTE*)mbi.BaseAddress;
        SIZE_T rsize = mbi.RegionSize;
        DWORD prot = mbi.Protect & 0xFF;
        BOOL exec = (mbi.State == MEM_COMMIT) &&
                    (prot == PAGE_EXECUTE_READ || prot == PAGE_EXECUTE_READWRITE ||
                     prot == PAGE_EXECUTE_WRITECOPY || prot == PAGE_EXECUTE);
        if (exec) {
            BYTE* q = base;
            BYTE* limit = base + rsize - 5;
            while (q < limit && reported < 60) {
                BYTE op = 0;
                __try { op = *q; } __except (EXCEPTION_EXECUTE_HANDLER) { break; }
                if (op == 0xE8 || op == 0xE9) {
                    DWORD rel = 0;
                    __try { rel = *(DWORD*)(q + 1); } __except (EXCEPTION_EXECUTE_HANDLER) { break; }
                    DWORD_PTR tgt = (DWORD_PTR)q + 5 + (LONG)rel;
                    if (tgt >= lo && tgt < hi) {
                        reported++;
                        Log("  %s at offset 0x%llX -> offset 0x%llX",
                            (op == 0xE8) ? "call" : "jmp",
                            (unsigned long long)((DWORD_PTR)q - g_modBase),
                            (unsigned long long)(tgt - g_modBase));
                    }
                }
                q++;
            }
        }
        p = base + rsize;
    }
    Log("[calls/jmps] %d", reported);
    Log("");
}

static DWORD WINAPI Worker(LPVOID) {
    Log("=== probe20 flag-check hunt (pid=%lu) ===", GetCurrentProcessId());
    HMODULE mf = NULL;
    for (int i = 0; i < 40 && !mf; i++) { mf = GetModuleHandleA("MainFrame.dll"); if (!mf) Sleep(500); }
    if (!mf) { Log("MainFrame.dll missing"); return 0; }
    g_modBase = (DWORD_PTR)mf;
    Log("MainFrame.dll base=0x%p", (void*)g_modBase);

    // 1) the call site that starts MCP
    DumpCode(0x57A0EE0, 0x57A1000, "around MCP-start call site");

    // 2) who calls the whole MCP launcher region (wider net)
    FindAllCallsInto(g_modBase + 0x57A0000, g_modBase + 0x57A2000);

    // 3) function entry for the caller
    FindFuncEntry(0x57A0F54, 0x57A0D00);

    Log("=== probe20 done ===");
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
