param(
    [int]$TargetPid,
    [string]$DllPath,
    [switch]$Probe
)

Add-Type @'
using System;
using System.Runtime.InteropServices;
using System.Text;

public static class Injector {
    [DllImport("kernel32.dll", SetLastError=true)]
    public static extern IntPtr OpenProcess(uint access, bool inherit, int pid);
    [DllImport("kernel32.dll", SetLastError=true)]
    public static extern IntPtr VirtualAllocEx(IntPtr h, IntPtr addr, uint size, uint type, uint protect);
    [DllImport("kernel32.dll", SetLastError=true)]
    public static extern bool WriteProcessMemory(IntPtr h, IntPtr addr, byte[] buf, uint size, out IntPtr written);
    [DllImport("kernel32.dll", SetLastError=true)]
    public static extern IntPtr GetModuleHandle(string name);
    [DllImport("kernel32.dll", SetLastError=true)]
    public static extern IntPtr GetProcAddress(IntPtr mod, string name);
    [DllImport("kernel32.dll", SetLastError=true)]
    public static extern IntPtr CreateRemoteThread(IntPtr h, IntPtr attr, uint stack, IntPtr start, IntPtr param, uint flags, IntPtr tid);
    [DllImport("kernel32.dll", SetLastError=true)]
    public static extern uint WaitForSingleObject(IntPtr h, uint ms);
    [DllImport("kernel32.dll", SetLastError=true)]
    public static extern bool GetExitCodeThread(IntPtr h, out uint code);
    [DllImport("kernel32.dll", SetLastError=true)]
    public static extern bool CloseHandle(IntPtr h);
    [DllImport("kernel32.dll", SetLastError=true)]
    public static extern bool VirtualFreeEx(IntPtr h, IntPtr addr, uint size, uint freeType);
    [DllImport("advapi32.dll", SetLastError=true)]
    public static extern bool OpenProcessToken(IntPtr proc, uint access, out IntPtr token);
    [DllImport("kernel32.dll", SetLastError=true)]
    public static extern IntPtr GetCurrentProcess();

    public const uint PROCESS_ALL_ACCESS = 0x1F0FFF;
    public const uint MEM_COMMIT_RESERVE = 0x3000;
    public const uint PAGE_READWRITE = 0x04;
    public const uint MEM_RELEASE = 0x8000;

    public static string Inject(int pid, string dllPath) {
        IntPtr h = OpenProcess(PROCESS_ALL_ACCESS, false, pid);
        if (h == IntPtr.Zero) {
            int err = Marshal.GetLastWin32Error();
            return "FAIL: OpenProcess error " + err + " (5=access denied, run elevated)";
        }
        try {
            byte[] pathBytes = Encoding.Unicode.GetBytes(dllPath + "\0");
            IntPtr remote = VirtualAllocEx(h, IntPtr.Zero, (uint)pathBytes.Length, MEM_COMMIT_RESERVE, PAGE_READWRITE);
            if (remote == IntPtr.Zero)
                return "FAIL: VirtualAllocEx error " + Marshal.GetLastWin32Error();

            IntPtr written;
            if (!WriteProcessMemory(h, remote, pathBytes, (uint)pathBytes.Length, out written))
                return "FAIL: WriteProcessMemory error " + Marshal.GetLastWin32Error();

            IntPtr k32 = GetModuleHandle("kernel32.dll");
            IntPtr loadLib = GetProcAddress(k32, "LoadLibraryW");
            if (loadLib == IntPtr.Zero)
                return "FAIL: LoadLibraryW not resolved";

            IntPtr th = CreateRemoteThread(h, IntPtr.Zero, 0, loadLib, remote, 0, IntPtr.Zero);
            if (th == IntPtr.Zero)
                return "FAIL: CreateRemoteThread error " + Marshal.GetLastWin32Error();

            uint wait = WaitForSingleObject(th, 15000);
            uint code = 0;
            GetExitCodeThread(th, out code);
            CloseHandle(th);
            VirtualFreeEx(h, remote, 0, MEM_RELEASE);

            if (wait != 0) return "FAIL: thread did not finish (wait=" + wait + ")";
            if (code == 0) return "FAIL: LoadLibraryW returned NULL in target (arch mismatch or load error)";
            return "OK: module base in target = 0x" + code.ToString("X");
        }
        finally {
            CloseHandle(h);
        }
    }
}
'@

# ---- diagnostics ----
$me = [System.Diagnostics.Process]::GetCurrentProcess()
Write-Host ("runner: {0}-bit | elevated={1} | pid={2}" -f `
    $(if ([Environment]::Is64BitProcess) {'64'} else {'32'}), `
    (New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator), `
    $me.Id)

if ($Probe) {
    Write-Host "=== CMSDING processes ==="
    Get-CimInstance Win32_Process -Filter "Name='CMSDING.exe'" | ForEach-Object {
        $isMain = -not ($_.CommandLine -match '--type=')
        $hasFrame = $false
        try { $hasFrame = [bool](Get-Process -Id $_.ProcessId).Modules | Where-Object { $_.ModuleName -eq 'MainFrame.dll' } } catch {}
        Write-Host ("  pid={0} main={1} mainframe={2} cmd={3}" -f $_.ProcessId, $isMain, $hasFrame, $_.CommandLine.Substring(0, [Math]::Min(70, $_.CommandLine.Length)))
    }
    return
}

if (-not $TargetPid -or -not $DllPath) { Write-Host "usage: inject.ps1 -TargetPid N -DllPath path [-Probe]"; return }

Write-Host ("injecting into pid {0}: {1}" -f $TargetPid, $DllPath)
$result = [Injector]::Inject($TargetPid, $DllPath)
Write-Host $result
