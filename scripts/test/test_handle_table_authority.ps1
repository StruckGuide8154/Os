# Security regression guard for the generic opaque-handle substrate used by VFS.
# The authoritative handle table must never move back into ring-3-writable slot
# memory. This is a source-level gate; normal kernel assembly/boot tests remain
# responsible for ABI/runtime coverage.

$ErrorActionPreference = 'Stop'
$Root = Resolve-Path (Join-Path $PSScriptRoot '..\..')
$Path = Join-Path $Root 'src\kernel\proc\handle_table.inc'
if (-not (Test-Path $Path)) { throw 'Missing handle_table.inc' }

$src = Get-Content -Raw -Path $Path

if ($src -notmatch '(?m)^kernel_handle_tables:\s+resb\s+APP_SLOT_COUNT\s*\*\s*L3_HANDLE_TABLE_SZ') {
    throw 'Authoritative per-slot handle tables are not reserved in kernel BSS'
}
if ($src -notmatch '(?m)^slot_handle_quota:\s+resb\s+APP_SLOT_COUNT') {
    throw 'Handle quota is not kernel-owned'
}
if ($src -match '(?m)^\s*add\s+rdi,\s*L3_HANDLE_TABLE_OFF\b') {
    throw 'Handle authority regressed to ring-3 slot memory'
}
if ($src -match '(?m)^\s*add\s+r11,\s*L3_HANDLE_TABLE_OFF\b') {
    throw 'Handle authority regressed to ring-3 slot memory'
}
if ($src -match '(?m)^\s*USER_ACCESS_BEGIN\b') {
    throw 'Authoritative handle table unexpectedly requires access to user pages'
}
if ($src -notmatch '(?s)handle_table_clear:.*?call\s+handle_bump_generation') {
    throw 'Slot recycle does not invalidate stored handle generations'
}
if ($src -notmatch '(?s)handle_close:.*?call\s+handle_bump_generation') {
    throw 'Close does not invalidate the handle generation immediately'
}
if ($src -notmatch '(?m)^\s*test\s+rdx,\s*APP_SLOT_SIZE\s*-\s*1\b') {
    throw 'Slot-base alignment check missing from handle authority lookup'
}

Write-Host 'Handle authority: PASS (kernel BSS, slot-local, generation-invalidating).' -ForegroundColor Green
