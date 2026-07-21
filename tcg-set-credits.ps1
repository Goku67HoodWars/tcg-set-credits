<#
  tcg-set-credits.ps1  -  Set OSRS-TCG plugin credits by editing the local RuneLite save.

  Multi-account safe: every RuneScape profile's save is decoded, edited, and re-hashed
  INDEPENDENTLY, so accounts never overwrite each other. Only the "credits" field changes;
  each account keeps its own collection.

  The plugin stores state as  RLTCG_v2:<base64(xor(gzip(json)))>  guarded by a SHA-256 hash.

  USAGE (close RuneLite first!):
    # interactive - lists your accounts and asks for the amount:
    powershell -NoProfile -ExecutionPolicy Bypass -File .\tcg-set-credits.ps1

    # non-interactive:
    powershell -NoProfile -ExecutionPolicy Bypass -File .\tcg-set-credits.ps1 -Credits 5692500 -Yes

    # only one account (substring of the profile id, e.g. A1b2C3d4):
    powershell ... -File .\tcg-set-credits.ps1 -Credits 5000000 -Account A1b2C3d4 -Yes

  Originals are copied to  <.runelite>\OSRS-TCG\pre-edit-backup-<timestamp>\  first.
#>
param(
    [long]$Credits = -1,
    [string]$RuneLiteDir = (Join-Path $env:USERPROFILE ".runelite"),
    [string]$Account = "",
    [switch]$NoPropertiesPatch,
    [switch]$NoBackupFiles,
    [switch]$Yes
)

$ErrorActionPreference = 'Stop'
$salt   = [byte[]](0x52,0x4c,0x54,0x43,0x47,0x7c,0x6f,0x73,0x72,0x73,0x2d,0x74,0x63,0x67,0x21)
$prefix = "RLTCG_v2:"

function Decode([string]$stored) {
    $stored = $stored.Trim()
    if (-not $stored.StartsWith($prefix)) { throw "not an RLTCG_v2 blob" }
    $b = [Convert]::FromBase64String($stored.Substring($prefix.Length))
    for ($i=0; $i -lt $b.Length; $i++) { $b[$i] = $b[$i] -bxor $salt[$i % $salt.Length] }
    $ms = New-Object System.IO.MemoryStream(,$b)
    $gz = New-Object System.IO.Compression.GZipStream($ms,[System.IO.Compression.CompressionMode]::Decompress)
    $sr = New-Object System.IO.StreamReader($gz,[System.Text.Encoding]::UTF8)
    try { return $sr.ReadToEnd() } finally { $sr.Close() }
}
function Encode([string]$json) {
    $utf8 = [System.Text.Encoding]::UTF8.GetBytes($json)
    $ms = New-Object System.IO.MemoryStream
    $gz = New-Object System.IO.Compression.GZipStream($ms,[System.IO.Compression.CompressionMode]::Compress,$true)
    $gz.Write($utf8,0,$utf8.Length); $gz.Close()
    $c = $ms.ToArray()
    for ($i=0; $i -lt $c.Length; $i++) { $c[$i] = $c[$i] -bxor $salt[$i % $salt.Length] }
    return $prefix + [Convert]::ToBase64String($c)
}
function Sha256Hex([string]$s) {
    $sha = [System.Security.Cryptography.SHA256]::Create()
    return (($sha.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($s)) | ForEach-Object { $_.ToString('x2') }) -join '')
}
# Java .properties value un-escaping. Blobs only ever contain \: and \= (base64 has no other escapes).
function Unescape([string]$v) { return $v.Replace('\:', ':').Replace('\=', '=') }
# Escape the value the way java.util.Properties does (: and = -> \: \=) so RuneLite reads it back identically.
function EscapeVal([string]$blob) { return $blob.Replace(':', '\:').Replace('=', '\=') }
function GetCredits([string]$json) { return [regex]::Match($json,'"credits":\s*(-?\d+)').Groups[1].Value }
function GetOpened([string]$json)  { return [regex]::Match($json,'"openedPacks":\s*(-?\d+)').Groups[1].Value }
function SetCreditsJson([string]$json, [long]$n) {
    $rx = [regex]'"credits":\s*-?\d+'
    if (-not $rx.IsMatch($json)) { throw "no credits field" }
    return $rx.Replace($json, ('"credits":' + $n), 1)
}
# Re-encode a stored blob with a new credits value -> @{ blob; hash; before }
function RebuildBlob([string]$storedBlob, [long]$n) {
    $json  = Decode $storedBlob
    $before = GetCredits $json
    $blob2 = Encode (SetCreditsJson $json $n)
    if ((GetCredits (Decode $blob2)) -ne "$n") { throw "round-trip failed" }
    return @{ blob = $blob2; hash = (Sha256Hex $blob2); before = $before }
}

# ---------- paths ----------
if ($Credits -ge 0 -and $Credits -gt 2147483647000) { throw "amount looks unreasonable" }
$backupsRoot = Join-Path $RuneLiteDir "OSRS-TCG\backups"
$profilesDir = Join-Path $RuneLiteDir "profiles2"
if (-not (Test-Path $profilesDir) -and -not (Test-Path $backupsRoot)) { throw "No RuneLite save found under $RuneLiteDir" }

if (Get-Process -Name RuneLite,javaw,java -ErrorAction SilentlyContinue) {
    Write-Warning "RuneLite/Java appears to be running. CLOSE the RuneLite client first, or the edit is overwritten on logout."
}

# ---------- discover accounts from properties ----------
# targets: list of @{ File; Account; Idx=@{state;hash;stateBackup;hashBackup}; Lines=[ref]string[] }
$fileLines = @{}
$targets = @()
$propsFiles = @()
if (Test-Path $profilesDir) { $propsFiles = Get-ChildItem $profilesDir -Filter *.properties -File -ErrorAction SilentlyContinue }
foreach ($pf in $propsFiles) {
    $raw = [System.IO.File]::ReadAllText($pf.FullName)
    if ($raw -notmatch 'osrstcg\.') { continue }
    $nl = if ($raw -match "`r`n") { "`r`n" } else { "`n" }
    $lines = $raw -split "`r`n|`n"
    $fileLines[$pf.FullName] = @{ nl = $nl; lines = $lines }
    $accts = @{}
    for ($i=0; $i -lt $lines.Count; $i++) {
        $m = [regex]::Match($lines[$i], '^osrstcg\.(.+)\.(state|hash|stateBackup|hashBackup)=')
        if (-not $m.Success) { continue }
        $id = $m.Groups[1].Value; $sub = $m.Groups[2].Value
        if (-not $accts.ContainsKey($id)) { $accts[$id] = @{} }
        $accts[$id][$sub] = $i
    }
    foreach ($id in $accts.Keys) {
        if (-not $accts[$id].ContainsKey('state')) { continue }
        $targets += [pscustomobject]@{ File = $pf.FullName; Account = $id; Idx = $accts[$id] }
    }
}

if ($Account -ne "") { $targets = @($targets | Where-Object { $_.Account -like "*$Account*" }) }

# ---------- show current state ----------
Write-Host "RuneLite dir: $RuneLiteDir" -ForegroundColor DarkGray
if ($targets.Count -eq 0 -and -not (Test-Path $backupsRoot)) { throw "No OSRS-TCG accounts found." }
Write-Host "Accounts found:" -ForegroundColor Cyan
foreach ($t in $targets) {
    $val = Unescape ($fileLines[$t.File].lines[$t.Idx.state] -replace '^[^=]*=','')
    $j = Decode $val
    Write-Host ("  {0}   credits={1}  openedPacks={2}" -f $t.Account, (GetCredits $j), (GetOpened $j))
}
if ($targets.Count -eq 0) { Write-Host "  (none in properties; will edit backup files only)" -ForegroundColor DarkGray }

# ---------- amount ----------
if ($Credits -lt 0) {
    $ans = Read-Host "`nEnter credit amount to SET for the above account(s)"
    [long]$parsed = 0
    if (-not [long]::TryParse(($ans -replace '[,\s]',''), [ref]$parsed)) { throw "Not a number: $ans" }
    $Credits = $parsed
}
if ($Credits -lt 0) { throw "Credits must be >= 0" }

if (-not $Yes) {
    $c = Read-Host ("`nSet credits to {0} for {1} account(s)? Make sure RuneLite is CLOSED. (y/N)" -f $Credits, $targets.Count)
    if ($c -notmatch '^(y|yes)$') { Write-Host "Aborted - nothing changed." -ForegroundColor Yellow; return }
}

# ---------- safety copy ----------
$stamp = Get-Date -Format "yyyyMMdd-HHmmss"
$preDir = Join-Path $RuneLiteDir ("OSRS-TCG\pre-edit-backup-" + $stamp)
New-Item -ItemType Directory -Force -Path $preDir | Out-Null
if (Test-Path $backupsRoot) { Copy-Item $backupsRoot -Destination (Join-Path $preDir "backups") -Recurse -Force }
foreach ($p in $fileLines.Keys) { Copy-Item $p -Destination (Join-Path $preDir (Split-Path $p -Leaf)) -Force }
Write-Host "Originals copied to: $preDir`n" -ForegroundColor DarkGray

# ---------- patch properties (each account independently) ----------
if (-not $NoPropertiesPatch) {
    foreach ($t in $targets) {
        $lines = $fileLines[$t.File].lines
        $stateVal = Unescape ($lines[$t.Idx.state] -replace '^[^=]*=','')
        $r = RebuildBlob $stateVal $Credits
        $key = ($lines[$t.Idx.state] -split '=',2)[0]
        $lines[$t.Idx.state] = $key + '=' + (EscapeVal $r.blob)
        if ($t.Idx.ContainsKey('hash')) { $lines[$t.Idx.hash] = (($lines[$t.Idx.hash] -split '=',2)[0]) + '=' + $r.hash }
        if ($t.Idx.ContainsKey('stateBackup')) {
            $bVal = Unescape ($lines[$t.Idx.stateBackup] -replace '^[^=]*=','')
            $rb = RebuildBlob $bVal $Credits
            $lines[$t.Idx.stateBackup] = (($lines[$t.Idx.stateBackup] -split '=',2)[0]) + '=' + (EscapeVal $rb.blob)
            if ($t.Idx.ContainsKey('hashBackup')) { $lines[$t.Idx.hashBackup] = (($lines[$t.Idx.hashBackup] -split '=',2)[0]) + '=' + $rb.hash }
        }
        Write-Host ("  properties: {0}  {1} -> {2}" -f $t.Account, $r.before, $Credits) -ForegroundColor Gray
    }
    foreach ($p in $fileLines.Keys) {
        $enc = New-Object System.Text.UTF8Encoding($false)
        [System.IO.File]::WriteAllText($p, (($fileLines[$p].lines) -join $fileLines[$p].nl), $enc)
    }
}

# ---------- patch file backups (each file by its own content) ----------
if (-not $NoBackupFiles -and (Test-Path $backupsRoot)) {
    $dirs = @()
    if ($Account -ne "") { foreach ($t in $targets) { $dirs += (Join-Path $backupsRoot (Sha256Hex $t.Account)) } }
    else { $dirs = (Get-ChildItem $backupsRoot -Directory -ErrorAction SilentlyContinue).FullName }
    $now = Get-Date
    foreach ($d in ($dirs | Select-Object -Unique)) {
        if (-not (Test-Path $d)) { continue }
        Get-ChildItem $d -File | Where-Object { $_.Name -match '^[a-fA-F0-9]{64}$' } | ForEach-Object {
            try {
                $blob = (Get-Content -Raw $_.FullName).Trim()
                $r = RebuildBlob $blob $Credits
                $dest = Join-Path $d $r.hash
                [System.IO.File]::WriteAllText($dest, $r.blob, (New-Object System.Text.UTF8Encoding($false)))
                if ($_.FullName -ne $dest) { Remove-Item $_.FullName -Force }
                (Get-Item $dest).LastWriteTime = $now
                Write-Host ("  backup: {0}\{1}" -f (Split-Path $d -Leaf), $r.hash.Substring(0,12)) -ForegroundColor Gray
            } catch { Write-Warning ("skipped backup {0}: {1}" -f $_.Name, $_.Exception.Message) }
        }
    }
}

# ---------- verify ----------
Write-Host "`nVerifying..." -ForegroundColor Cyan
$ok = $true
foreach ($t in $targets) {
    $lines = ([System.IO.File]::ReadAllText($t.File)) -split "`r`n|`n"
    $line = $lines | Where-Object { $_ -match ('^osrstcg\.' + [regex]::Escape($t.Account) + '\.state=') } | Select-Object -First 1
    $j = Decode (Unescape ($line -replace '^[^=]*=',''))
    $c = GetCredits $j
    $good = ($c -eq "$Credits")
    if (-not $good) { $ok = $false }
    Write-Host ("  {0}: credits={1} openedPacks={2}  {3}" -f $t.Account, $c, (GetOpened $j), ($(if($good){'OK'}else{'FAIL'}))) -ForegroundColor $(if($good){'Green'}else{'Red'})
}

Write-Host ""
if ($ok) { Write-Host "Done. Start RuneLite; each account shows $Credits credits." -ForegroundColor Green }
else     { Write-Host "Something did not verify - restore from $preDir" -ForegroundColor Red }
Write-Host "Restore point: $preDir" -ForegroundColor DarkGray
