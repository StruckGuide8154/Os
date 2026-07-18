$ErrorActionPreference = 'Stop'

$Root = Resolve-Path (Join-Path $PSScriptRoot '..\..')
$WrapperPath = Join-Path $Root 'src\include\syscall_user.inc'
$GhlAbiPath = Join-Path $Root 'src\user\grithl\lib\core.ghl'
$TablePath = Join-Path $Root 'src\kernel\proc\syscall_support.inc'
$DocsPath = Join-Path $Root 'docs\syscalls.md'

$wrapperText = Get-Content -Path $WrapperPath -Raw
$ghlAbiText = Get-Content -Path $GhlAbiPath -Raw
$tableText = Get-Content -Path $TablePath -Raw
$docsText = Get-Content -Path $DocsPath -Raw

function Add-UniqueMapping {
    param(
        [hashtable]$Map,
        [int]$Number,
        [string]$Name,
        [string]$Owner
    )

    if ($Map.ContainsKey($Number)) {
        throw "$Owner defines syscall $Number more than once: $($Map[$Number]) and $Name."
    }
    $Map[$Number] = $Name
}

# The public wrapper name and APP_SYSNO immediate are kept together inside each
# macro, making this the user-visible ABI source of truth.
$wrappers = @{}
$wrapperPattern = '(?ms)^%macro[ \t]+(SYS_[A-Z0-9_]+)[ \t]+\d+[ \t]*\r?$.*?^[ \t]*APP_SYSNO[ \t]+(\d+)[ \t]*\r?$.*?^%endmacro[ \t]*\r?$'
foreach ($match in [regex]::Matches($wrapperText, $wrapperPattern)) {
    Add-UniqueMapping $wrappers ([int]$match.Groups[2].Value) $match.Groups[1].Value $WrapperPath
}
if ($wrappers.Count -eq 0) {
    throw "No syscall wrappers were parsed from $WrapperPath."
}

# Newer GritHL-only APIs use named constants rather than NASM wrapper macros.
# Merge both public surfaces by symbolic name. GritHL intentionally has a few
# shorter aliases (for example SYS_DISPLAY_MODE), so multiple names may map to
# one row; a single name may never map to two rows.
$publicAbiByName = @{}
foreach ($number in $wrappers.Keys) {
    $publicAbiByName[$wrappers[$number]] = $number
}
foreach ($match in [regex]::Matches($ghlAbiText, '(?m)^const[ \t]+(SYS_[A-Z0-9_]+)[ \t]*=[ \t]*(\d+)[ \t]*\r?$')) {
    $number = [int]$match.Groups[2].Value
    $name = $match.Groups[1].Value
    if ($publicAbiByName.ContainsKey($name) -and $publicAbiByName[$name] -ne $number) {
        throw "Public ABI name drift: $name maps to $($publicAbiByName[$name]) and $number."
    }
    $publicAbiByName[$name] = $number
}

# Rows 0..80 are one SYSCALL_ENTRY apiece. The later sparse driver ABI begins
# at the first %rep, so it is deliberately outside this public-app docs guard.
$publicTableText = $tableText.Substring(
    $tableText.IndexOf('syscall_table:'),
    $tableText.IndexOf('%rep', $tableText.IndexOf('syscall_table:')) - $tableText.IndexOf('syscall_table:')
)
$table = @{}
$row = 0
foreach ($match in [regex]::Matches($publicTableText, '(?m)^\s*SYSCALL_ENTRY\s+syscall_entry\.(sc_[a-z0-9_]+),')) {
    Add-UniqueMapping $table $row $match.Groups[1].Value $TablePath
    $row++
}

if ($table.Count -ne 81) {
    throw "Expected 81 public syscall-table rows (0..80), found $($table.Count)."
}

# Validate every individually documented syscall heading. Range headings such
# as "31 through 39" are explanatory and intentionally do not match here.
$docs = @{}
foreach ($match in [regex]::Matches($docsText, '(?m)^`(\d+)` `(SYS_[A-Z0-9_]+)`\s*$')) {
    Add-UniqueMapping $docs ([int]$match.Groups[1].Value) $match.Groups[2].Value $DocsPath
}
if ($docs.Count -eq 0) {
    throw "No syscall headings were parsed from $DocsPath."
}

foreach ($number in $docs.Keys) {
    $documentedName = $docs[$number]
    if (-not $publicAbiByName.ContainsKey($documentedName)) {
        throw "docs/syscalls.md documents $number ($($docs[$number])) without a public ABI definition."
    }
    if ($publicAbiByName[$documentedName] -ne $number) {
        throw "Syscall name drift: docs map $documentedName to $number; public ABI maps it to $($publicAbiByName[$documentedName])."
    }
}

# The original stable ABI range is explicitly documented as 0..21. Keep it
# contiguous and prove that docs, wrappers, and dispatch rows all agree.
foreach ($number in 0..21) {
    if (-not $docs.ContainsKey($number)) {
        throw "docs/syscalls.md is missing required core syscall $number (documented range 0..21)."
    }
    if (-not $wrappers.ContainsKey($number)) {
        throw "syscall_user.inc is missing required core syscall wrapper $number."
    }
    if (-not $table.ContainsKey($number)) {
        throw "syscall_support.inc is missing required core syscall-table row $number."
    }

    $expectedHandler = 'sc_' + $wrappers[$number].Substring(4).ToLowerInvariant()
    if ($table[$number] -ne $expectedHandler) {
        throw "Syscall $number dispatch drift: $($wrappers[$number]) expects $expectedHandler, table uses $($table[$number])."
    }
}

Write-Host "[syscall-docs] PASS: $($docs.Count) documented entries match wrappers; core range 0..21 matches all 22 table rows." -ForegroundColor Green
