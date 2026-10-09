// dtinject19.cpp - dump the MCP code region inside MainFrame.dll so we can find
// function boundaries (int3 padding) and the start-up routine, then look for call
// sites into it (which is where the enable_mcp_server flag check lives).
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
    _snprintf_s(g_logPath, MAX_PATH, _TRUNCATE, "%sprobe19.log", mod);
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

static void DumpCode(DWORD_PTR fromOff, DWORD_PTR toOff) {
    Log("--- dump module offsets 0x%llX .. 0x%llX ---",
        (unsigned long long)fromOff, (unsigned long long)toOff);
    for (DWORD_PTR off = fromOff; off < toOff; off += 32) {
        BYTE b[32];
        int ok = 1;
        __try { memcpy(b, (void*)(g_modBase + off), 32); }
        __except (EXCEPTION_EXECUTE_HANDLER) { ok = 0; }
        if (!ok) { Log("  %08llX: <unreadable>", (unsigned long long)off); continue; }
        char hex[130] = {0};
        int ci = 0;
        for (int i = 0; i < 32; i++)
            ci += _snprintf_s(hex + ci, sizeof(hex) - ci, _TRUNCATE, "%02X ", b[i]);
        Log("  %08llX: %s", (unsigned long long)off, hex);
    }
    Log("");
}

// mark int3 padding runs (function separators) inside a range
static void MarkPadding(DWORD_PTR fromOff, DWORD_PTR toOff) {
    Log("--- int3 padding (function separators) ---");
    DWORD_PTR runStart = 0;
    int run = 0;
    for (DWORD_PTR off = fromOff; off < toOff; off++) {
        BYTE v = 0;
        __try { v = *(BYTE*)(g_modBase + off); } __except (EXCEPTION_EXECUTE_HANDLER) { break; }
        if (v == 0xCC || v == 0x90) {
            if (run == 0) runStart = off;
            run++;
        } else {
            if (run >= 3) Log("  pad 0x%08llX .. 0x%08llX (%d bytes) -> next code at 0x%08llX",
                              (unsigned long long)runStart, (unsigned long long)(off - 1), run,
                              (unsigned long long)off);
            run = 0;
        }
    }
    if (run >= 3) Log("  pad 0x%08llX .. 0x%08llX (%d bytes)",
                      (unsigned long long)runStart, (unsigned long long)(toOff - 1), run);
    Log("");
}

// find call rel32 sites that target any address inside [lo,hi)
static void FindCallsInto(DWORD_PTR lo, DWORD_PTR hi) {
    Log("--- call sites into 0x%llX..0x%llX ---",
        (unsigned long long)lo, (unsigned long long)hi);
    int reported = 0;
    BYTE* p = (BYTE*)g_modBase;
    // scan the whole image but only executable regions
    DWORD_PTR end = g_modBase + 0x9450000ULL;
    while ((DWORD_PTR)p < end && reported < 40) {
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
            while (q < limit && reported < 40) {
                BYTE op = 0;
                __try { op = *q; } __except (EXCEPTION_EXECUTE_HANDLER) { break; }
                if (op == 0xE8) {   // call rel32
                    DWORD rel = 0;
                    __try { rel = *(DWORD*)(q + 1); } __except (EXCEPTION_EXECUTE_HANDLER) { break; }
                    DWORD_PTR tgt = (DWORD_PTR)q + 5 + (LONG)rel;
                    if (tgt >= lo && tgt < hi) {
                        reported++;
                        Log("  call at moduleOffset 0x%llX -> 0x%llX",
                            (unsigned long long)((DWORD_PTR)q - g_modBase), (unsigned long long)tgt);
                    }
                }
                q++;
            }
        }
        p = base + rsize;
    }
    Log("[calls] found: %d", reported);
    Log("");
}

static DWORD WINAPI Worker(LPVOID) {
    Log("=== probe19 MCP code dump (pid=%lu) ===", GetCurrentProcessId());
    HMODULE mf = NULL;
    for (int i = 0; i < 40 && !mf; i++) { mf = GetModuleHandleA("MainFrame.dll"); if (!mf) Sleep(500); }
    if (!mf) { Log("MainFrame.dll missing"); return 0; }
    g_modBase = (DWORD_PTR)mf;
    Log("MainFrame.dll base=0x%p", (void*)g_modBase);

    MarkPadding(0x57A9000, 0x57AD000);
    DumpCode(0x57AAF00, 0x57AB500);

    // call sites into the MCP start-up routine region
    FindCallsInto(g_modBase + 0x57AAF00, g_modBase + 0x57AB500);

    // also: who calls into the tool-registration region
    FindCallsInto(g_modBase + 0x57AA900, g_modBase + 0x57AAB00);

    Log("=== probe19 done ===");
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
