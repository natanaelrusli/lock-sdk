# Minimal OLE2 (CFB) + Word 97 .doc text extractor.
# No Word/LibreOffice/python on this box, so we parse the container ourselves.
param([Parameter(Mandatory=$true)][string]$Path,
      [Parameter(Mandatory=$true)][string]$OutFile)

$ErrorActionPreference = 'Stop'
$raw = [System.IO.File]::ReadAllBytes($Path)

# PowerShell 5.1 parses 0xFFFFFFFF as Int32 -1, so sentinel compares against
# uint32 values silently fail. Use explicit unsigned constants instead.
$FREESECT = [uint32]4294967295   # 0xFFFFFFFF
$CHAINEND = [uint32]4294967280   # $CHAINEND - anything >= this ends a chain

# ---- header ----
$sig = ($raw[0..7] | ForEach-Object { $_.ToString('X2') }) -join ''
if ($sig -ne 'D0CF11E0A1B11AE1') { throw "Not an OLE2 compound file (sig=$sig)" }

$sectorSize     = 1 -shl [BitConverter]::ToUInt16($raw, 0x1E)
$miniSectorSize = 1 -shl [BitConverter]::ToUInt16($raw, 0x20)
$numFatSectors  = [BitConverter]::ToUInt32($raw, 0x2C)
$firstDirSector = [BitConverter]::ToUInt32($raw, 0x30)
$miniCutoff     = [BitConverter]::ToUInt32($raw, 0x38)
$firstMiniFat   = [BitConverter]::ToUInt32($raw, 0x3C)
$numMiniFat     = [BitConverter]::ToUInt32($raw, 0x40)
$firstDifat     = [BitConverter]::ToUInt32($raw, 0x44)
$numDifat       = [BitConverter]::ToUInt32($raw, 0x48)

function Get-SectorOffset([uint32]$s) { return 512 + ([int]$s * $sectorSize) }

# ---- DIFAT -> list of FAT sector numbers ----
$fatSectors = New-Object System.Collections.Generic.List[uint32]
for ($i = 0; $i -lt 109; $i++) {
    $v = [BitConverter]::ToUInt32($raw, 0x4C + $i*4)
    if ($v -eq $FREESECT) { break }
    $fatSectors.Add($v)
}
$next = $firstDifat
for ($k = 0; $k -lt $numDifat -and $next -ne $FREESECT; $k++) {
    $off = Get-SectorOffset $next
    $perSector = [int]($sectorSize / 4) - 1
    for ($i = 0; $i -lt $perSector; $i++) {
        $v = [BitConverter]::ToUInt32($raw, $off + $i*4)
        if ($v -ne $FREESECT) { $fatSectors.Add($v) }
    }
    $next = [BitConverter]::ToUInt32($raw, $off + $perSector*4)
}

# ---- FAT ----
$fat = New-Object System.Collections.Generic.List[uint32]
foreach ($fs in $fatSectors) {
    $off = Get-SectorOffset $fs
    for ($i = 0; $i -lt ($sectorSize / 4); $i++) { $fat.Add([BitConverter]::ToUInt32($raw, $off + $i*4)) }
}

function Get-Chain([uint32]$start) {
    $chain = New-Object System.Collections.Generic.List[uint32]
    $cur = $start; $guard = 0
    while ($cur -lt $CHAINEND -and $guard -lt 100000) {
        $chain.Add($cur)
        if ($cur -ge $fat.Count) { break }
        $cur = $fat[[int]$cur]; $guard++
    }
    return $chain
}

function Read-SectorStream([uint32]$start, [int]$size) {
    $buf = New-Object byte[] $size
    $pos = 0
    foreach ($s in (Get-Chain $start)) {
        if ($pos -ge $size) { break }
        $n = [Math]::Min($sectorSize, $size - $pos)
        [Array]::Copy($raw, (Get-SectorOffset $s), $buf, $pos, $n)
        $pos += $n
    }
    return $buf
}

# ---- directory ----
$dirBytes = Read-SectorStream $firstDirSector ((Get-Chain $firstDirSector).Count * $sectorSize)
$entries = @{}
$rootStart = 0; $rootSize = 0
for ($i = 0; $i -lt ($dirBytes.Length / 128); $i++) {
    $b = $i * 128
    $nameLen = [BitConverter]::ToUInt16($dirBytes, $b + 64)
    if ($nameLen -le 2) { continue }
    $name = [System.Text.Encoding]::Unicode.GetString($dirBytes, $b, $nameLen - 2)
    $type = $dirBytes[$b + 66]
    $start = [BitConverter]::ToUInt32($dirBytes, $b + 116)
    $size  = [BitConverter]::ToUInt32($dirBytes, $b + 120)
    if ($type -eq 5) { $rootStart = $start; $rootSize = $size }
    if ($type -eq 2) { $entries[$name] = @{ Start = $start; Size = $size } }
}

# ---- mini stream support ----
$miniFat = New-Object System.Collections.Generic.List[uint32]
if ($numMiniFat -gt 0) {
    foreach ($s in (Get-Chain $firstMiniFat)) {
        $off = Get-SectorOffset $s
        for ($i = 0; $i -lt ($sectorSize / 4); $i++) { $miniFat.Add([BitConverter]::ToUInt32($raw, $off + $i*4)) }
    }
}
$miniStream = $null
if ($rootSize -gt 0) { $miniStream = Read-SectorStream $rootStart ([int](((Get-Chain $rootStart).Count) * $sectorSize)) }

function Read-Stream([string]$name) {
    if (-not $entries.ContainsKey($name)) { return $null }
    $e = $entries[$name]
    $size = [int]$e.Size
    if ($size -ge $miniCutoff) { return Read-SectorStream $e.Start $size }
    # mini stream
    $buf = New-Object byte[] $size
    $pos = 0; $cur = $e.Start; $guard = 0
    while ($pos -lt $size -and $cur -lt $CHAINEND -and $guard -lt 100000) {
        $n = [Math]::Min($miniSectorSize, $size - $pos)
        [Array]::Copy($miniStream, [int]$cur * $miniSectorSize, $buf, $pos, $n)
        $pos += $n
        if ($cur -ge $miniFat.Count) { break }
        $cur = $miniFat[[int]$cur]; $guard++
    }
    return $buf
}

Write-Host "streams: $($entries.Keys -join ', ')"

$wd = Read-Stream 'WordDocument'
if (-not $wd) { throw 'No WordDocument stream' }

# ---- FIB ----
$flags = [BitConverter]::ToUInt16($wd, 0x0A)
$tableName = if ($flags -band 0x0200) { '1Table' } else { '0Table' }
$tbl = Read-Stream $tableName
if (-not $tbl) { throw "No $tableName stream" }

$fcClx  = [BitConverter]::ToUInt32($wd, 0x01A2)
$lcbClx = [BitConverter]::ToUInt32($wd, 0x01A6)
Write-Host "table=$tableName fcClx=$fcClx lcbClx=$lcbClx"

# ---- walk CLX to the Pcdt (clxt 0x02) ----
$p = [int]$fcClx
$end = [int]($fcClx + $lcbClx)
$pcdtOff = -1; $lcbPlc = 0
while ($p -lt $end) {
    $clxt = $tbl[$p]
    if ($clxt -eq 1) {
        $cb = [BitConverter]::ToUInt16($tbl, $p + 1)
        $p += 3 + $cb
    } elseif ($clxt -eq 2) {
        $lcbPlc = [BitConverter]::ToUInt32($tbl, $p + 1)
        $pcdtOff = $p + 5
        break
    } else { break }
}
if ($pcdtOff -lt 0) { throw 'No Pcdt found in CLX' }

$nPieces = [int](($lcbPlc - 4) / 12)
Write-Host "pieces: $nPieces"

$gbk = [System.Text.Encoding]::GetEncoding(936)
$sb = New-Object System.Text.StringBuilder
for ($i = 0; $i -lt $nPieces; $i++) {
    $cpStart = [BitConverter]::ToUInt32($tbl, $pcdtOff + $i*4)
    $cpEnd   = [BitConverter]::ToUInt32($tbl, $pcdtOff + ($i+1)*4)
    $cch     = [int]($cpEnd - $cpStart)
    $pcdOff  = $pcdtOff + ($nPieces + 1) * 4 + $i * 8
    $fcRaw   = [BitConverter]::ToUInt32($tbl, $pcdOff + 2)
    $compressed = ($fcRaw -band 0x40000000) -ne 0
    $fc = $fcRaw -band 0x3FFFFFFF
    if ($compressed) {
        $fc = [int]($fc / 2)
        if ($fc + $cch -le $wd.Length) { [void]$sb.Append($gbk.GetString($wd, $fc, $cch)) }
    } else {
        if ($fc + $cch*2 -le $wd.Length) { [void]$sb.Append([System.Text.Encoding]::Unicode.GetString($wd, [int]$fc, $cch*2)) }
    }
}

$text = $sb.ToString()
$text = $text -replace "`r", "`r`n"
[System.IO.File]::WriteAllText($OutFile, $text, (New-Object System.Text.UTF8Encoding($true)))
Write-Host "extracted chars: $($text.Length) -> $OutFile"

