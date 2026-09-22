# Launch a GUI exe, harvest its visible control text, and classify each string as
# ASCII / correct-CJK / mojibake. For mojibake, recover the intended text by
# reversing the fault: re-encode as Latin-1, then decode as GBK.
#
# NOTE: this file is deliberately pure ASCII. PowerShell 5.1 reads .ps1 files
# without a BOM using the ANSI codepage, so any literal CJK here would itself be
# mangled - the very bug being audited. Character ranges are built from codepoints.
param([Parameter(Mandatory=$true)][string]$Exe,
      [string]$Label = '',
      [int]$WaitSeconds = 8)

. "$PSScriptRoot\WinDump.ps1"

$gbk    = [System.Text.Encoding]::GetEncoding(936)
$latin1 = [System.Text.Encoding]::GetEncoding(28591)

function Has-Cjk([string]$s) {
    foreach ($ch in $s.ToCharArray()) {
        $c = [int]$ch
        if ($c -ge 0x4E00 -and $c -le 0x9FFF) { return $true }
    }
    return $false
}
function Count-HiLatin([string]$s) {
    $n = 0
    foreach ($ch in $s.ToCharArray()) {
        $c = [int]$ch
        if ($c -ge 0x00A0 -and $c -le 0x00FF) { $n++ }
    }
    return $n
}

function Classify([string]$s) {
    if ([string]::IsNullOrWhiteSpace($s)) { return $null }
    if (Has-Cjk $s) { return [pscustomobject]@{ Kind='CJK-OK'; Text=$s; Recovered='' } }
    if ((Count-HiLatin $s) -ge 2) {
        try {
            $rec = $gbk.GetString($latin1.GetBytes($s))
            if (Has-Cjk $rec) { return [pscustomobject]@{ Kind='MOJIBAKE'; Text=$s; Recovered=$rec } }
        } catch {}
        return [pscustomobject]@{ Kind='SUSPECT'; Text=$s; Recovered='' }
    }
    return [pscustomobject]@{ Kind='ASCII'; Text=$s; Recovered='' }
}

$name = if ($Label) { $Label } else { Split-Path $Exe -Leaf }
Write-Output "=============================================================="
Write-Output "APP : $name"

if (-not (Test-Path -LiteralPath $Exe)) { Write-Output "  RESULT: MISSING"; return }

try { $proc = Start-Process -FilePath $Exe -WorkingDirectory (Split-Path $Exe -Parent) -PassThru -ErrorAction Stop }
catch { Write-Output "  RESULT: FAILED TO START"; return }

$deadline = (Get-Date).AddSeconds($WaitSeconds)
while ((Get-Date) -lt $deadline) {
    Start-Sleep -Milliseconds 500
    $proc.Refresh()
    if ($proc.HasExited -or $proc.MainWindowHandle -ne [IntPtr]::Zero) { break }
}
Start-Sleep -Milliseconds 1000
$proc.Refresh()

if ($proc.HasExited) {
    $hex = '0x{0:X8}' -f $proc.ExitCode
    Write-Output "  RESULT: CRASHED/EXITED ($hex)"
} else {
    $strings = @()
    try { $strings = [Win32Windows]::Dump([uint32]$proc.Id) } catch {}
    $nAscii = 0; $nCjk = 0; $nMoji = 0
    $samples = @()
    foreach ($s in $strings) {
        $c = Classify $s
        if ($null -eq $c) { continue }
        switch ($c.Kind) {
            'ASCII'    { $nAscii++ }
            'CJK-OK'   { $nCjk++ }
            'MOJIBAKE' { $nMoji++; if ($samples.Count -lt 3) { $samples += $c } }
        }
    }
    $verdict = if ($nMoji -gt 0) { 'GARBLED' } elseif ($nCjk -gt 0) { 'OK (Chinese)' } else { 'OK (English)' }
    Write-Output ("  RESULT: RUNNING | {0} | ascii={1} cjk={2} mojibake={3}" -f $verdict, $nAscii, $nCjk, $nMoji)
    foreach ($s in $samples) { Write-Output ("     shown: {0}" -f $s.Text); Write-Output ("     means: {0}" -f $s.Recovered) }
}

try { if (-not $proc.HasExited) { Stop-Process -Id $proc.Id -Force -ErrorAction SilentlyContinue } } catch {}
