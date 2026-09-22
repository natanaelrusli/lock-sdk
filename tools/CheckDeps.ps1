# Resolve the import table of every binary in a folder against the folder itself
# and the system directories, reporting anything that cannot be found.
# These are 32-bit binaries, so SysWOW64 is the correct system dir.
param([Parameter(Mandatory=$true)][string]$Folder)

$vs = 'C:\Program Files\Microsoft Visual Studio\18\Community'
$mv = Get-ChildItem "$vs\VC\Tools\MSVC" -Directory | Select-Object -First 1 -ExpandProperty Name
$dumpbin = "$vs\VC\Tools\MSVC\$mv\bin\Hostx64\x64\dumpbin.exe"

function Get-Imports($file) {
    $out = & $dumpbin /dependents $file 2>$null
    $mods = @()
    $in = $false
    foreach ($line in $out) {
        if ($line -match 'Image has the following dependencies') { $in = $true; continue }
        if ($in) {
            if ($line -match '^\s*(\S+\.[Dd][Ll][Ll])\s*$') { $mods += $matches[1] }
            elseif ($line -match '^\s*Summary') { break }
        }
    }
    return $mods
}

$sysDirs = @("$env:WINDIR\SysWOW64", "$env:WINDIR\System32")
$local = @{}
Get-ChildItem -LiteralPath $Folder -File -Filter *.dll -ErrorAction SilentlyContinue |
    ForEach-Object { $local[$_.Name.ToLower()] = $true }

function Resolve-Mod($m) {
    $lm = $m.ToLower()
    if ($local.ContainsKey($lm)) { return 'local' }
    if ($lm -like 'api-ms-win-*' -or $lm -like 'ext-ms-*') { return 'apiset' }
    foreach ($d in $sysDirs) { if (Test-Path (Join-Path $d $m)) { return 'system' } }
    return 'MISSING'
}

$binaries = Get-ChildItem -LiteralPath $Folder -File -ErrorAction SilentlyContinue |
    Where-Object { $_.Extension -in '.exe', '.dll' -and $_.Length -gt 2048 }

$missingAll = @{}
foreach ($b in $binaries) {
    $imports = Get-Imports $b.FullName
    $bad = @()
    foreach ($m in $imports) {
        if ((Resolve-Mod $m) -eq 'MISSING') { $bad += $m; $missingAll[$m] = $true }
    }
    if ($bad.Count -gt 0) { "  {0,-24} needs: {1}" -f $b.Name, ($bad -join ', ') }
}

if ($missingAll.Count -eq 0) { "  (all imports resolve)" }
else { "`n  UNRESOLVED IN THIS FOLDER: " + (($missingAll.Keys | Sort-Object) -join ', ') }
