# Launch a GUI exe, report whether it survives, and dump its visible window text.
# Purely observational: enumerates windows, clicks nothing, then terminates.
param([Parameter(Mandatory=$true)][string]$Exe,
      [int]$WaitSeconds = 6)

if (-not ('Win32Windows' -as [type])) {
Add-Type @'
using System;
using System.Text;
using System.Collections.Generic;
using System.Runtime.InteropServices;
public class Win32Windows {
    [DllImport("user32.dll")] static extern bool EnumWindows(EnumProc cb, IntPtr p);
    [DllImport("user32.dll")] static extern bool EnumChildWindows(IntPtr h, EnumProc cb, IntPtr p);
    [DllImport("user32.dll")] static extern int GetWindowTextLength(IntPtr h);
    [DllImport("user32.dll", CharSet=CharSet.Unicode)] static extern int GetWindowText(IntPtr h, StringBuilder s, int n);
    [DllImport("user32.dll", CharSet=CharSet.Unicode)] static extern int GetClassName(IntPtr h, StringBuilder s, int n);
    [DllImport("user32.dll")] static extern bool IsWindowVisible(IntPtr h);
    [DllImport("user32.dll")] static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
    delegate bool EnumProc(IntPtr h, IntPtr p);

    static string Text(IntPtr h) {
        int n = GetWindowTextLength(h);
        if (n <= 0) return "";
        StringBuilder sb = new StringBuilder(n + 2);
        GetWindowText(h, sb, sb.Capacity);
        return sb.ToString();
    }
    static string Cls(IntPtr h) {
        StringBuilder sb = new StringBuilder(128);
        GetClassName(h, sb, sb.Capacity);
        return sb.ToString();
    }

    public static List<string> Dump(uint targetPid) {
        List<string> outp = new List<string>();
        EnumWindows(delegate(IntPtr h, IntPtr p) {
            uint pid; GetWindowThreadProcessId(h, out pid);
            if (pid != targetPid || !IsWindowVisible(h)) return true;
            outp.Add("WINDOW [" + Cls(h) + "] " + Text(h));
            EnumChildWindows(h, delegate(IntPtr c, IntPtr q) {
                if (!IsWindowVisible(c)) return true;
                string t = Text(c);
                if (t.Length > 0) outp.Add("   - [" + Cls(c) + "] " + t);
                return true;
            }, IntPtr.Zero);
            return true;
        }, IntPtr.Zero);
        return outp;
    }
}
'@ -Language CSharp
}

$name = Split-Path $Exe -Leaf
$dir  = Split-Path $Exe -Parent
Write-Output "=============================================================="
Write-Output "EXE : $name"
Write-Output "DIR : $dir"

if (-not (Test-Path -LiteralPath $Exe)) { Write-Output "RESULT: MISSING"; return }

$proc = $null
try {
    $proc = Start-Process -FilePath $Exe -WorkingDirectory $dir -PassThru -ErrorAction Stop
} catch {
    Write-Output "RESULT: FAILED TO START - $($_.Exception.Message)"
    return
}

# poll for a window
$deadline = (Get-Date).AddSeconds($WaitSeconds)
$hasWindow = $false
while ((Get-Date) -lt $deadline) {
    Start-Sleep -Milliseconds 500
    $proc.Refresh()
    if ($proc.HasExited) { break }
    if ($proc.MainWindowHandle -ne [IntPtr]::Zero) { $hasWindow = $true; break }
}
Start-Sleep -Milliseconds 1200
$proc.Refresh()

if ($proc.HasExited) {
    Write-Output "RESULT: EXITED EARLY (code $($proc.ExitCode))"
} else {
    Write-Output "RESULT: RUNNING (pid $($proc.Id))  window=$hasWindow"
    try {
        $dump = [Win32Windows]::Dump([uint32]$proc.Id)
        if ($dump.Count -gt 0) { $dump | ForEach-Object { Write-Output $_ } }
        else { Write-Output "   (no visible window text)" }
    } catch { Write-Output "   (window enumeration failed: $($_.Exception.Message))" }
}

# always clean up
try { if (-not $proc.HasExited) { Stop-Process -Id $proc.Id -Force -ErrorAction SilentlyContinue } } catch {}
Get-Process -Name ([System.IO.Path]::GetFileNameWithoutExtension($name)) -ErrorAction SilentlyContinue |
    Where-Object { $_.Path -eq $Exe } | Stop-Process -Force -ErrorAction SilentlyContinue
