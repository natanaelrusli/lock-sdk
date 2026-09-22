# Shared Win32 window-text enumerator used by the audit scripts.
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

    public static List<string> Dump(uint targetPid) {
        List<string> outp = new List<string>();
        EnumWindows(delegate(IntPtr h, IntPtr p) {
            uint pid; GetWindowThreadProcessId(h, out pid);
            if (pid != targetPid || !IsWindowVisible(h)) return true;
            string wt = Text(h);
            if (wt.Length > 0) outp.Add(wt);
            EnumChildWindows(h, delegate(IntPtr c, IntPtr q) {
                if (!IsWindowVisible(c)) return true;
                string t = Text(c);
                if (t.Length > 0) outp.Add(t);
                return true;
            }, IntPtr.Zero);
            return true;
        }, IntPtr.Zero);
        return outp;
    }
}
'@ -Language CSharp
}
