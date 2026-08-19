# Compile/security gate for VFS's bounded no-steal lock service.

$ErrorActionPreference = 'Stop'
$Root = Resolve-Path (Join-Path $PSScriptRoot '..\..')
$Compiler = Join-Path $Root 'src\user\grithl\compiler\gritc.py'
$Source = Join-Path $Root 'src\kernel\grithlk\vfs_lock.ghl'
$Lib = Join-Path $Root 'src\user\grithl\lib'
$OutDir = Join-Path $Root 'build\test-vfs'
$Asm = Join-Path $OutDir 'vfs_lock.asm'
$Safety = Join-Path $OutDir 'vfs_lock.safety.json'

New-Item -Path $OutDir -ItemType Directory -Force | Out-Null
Write-Host 'VFS lock: compiling bounded no-steal lock service...' -ForegroundColor Yellow
& python $Compiler $Source -o $Asm -L $Lib --embed --target kernel --forbid-asm --safety-manifest $Safety
if ($LASTEXITCODE -ne 0) { throw 'vfs_lock.ghl failed GritHLK compilation' }

$m = Get-Content -Raw -Path $Safety | ConvertFrom-Json
$declared = @($m.unsafe.declared | ForEach-Object {
    if ($null -ne $_.cap) { [string]$_.cap } else { [string]$_ }
} | Sort-Object)
$expected = @('implicit_extern','kernel_priv','raw_mem')
if (($declared -join ',') -ne ($expected -join ',')) {
    throw "VFS lock unsafe surface drifted: expected [$($expected -join ', ')], got [$($declared -join ', ')]"
}

$src = Get-Content -Raw -Path $Source
if ($src -match '(?m)^\s*unsafe\s+(asm|raw_io|user_mem|syscall|kernel_io)\b') {
    throw 'VFS lock gained authority beyond atomics over module-owned kernel state'
}
if ($src -notmatch 'const\s+VFS_LOCK_MAX_SPINS\s*=\s*65536;') {
    throw 'VFS lock no longer has a hard wait bound'
}
if ($src -notmatch '(?s)fn\s+vfs_lock_acquire\(id,\s*spin_budget\).*?atomic_cmpxchg\(p,\s*0,\s*tag\)\s*==\s*0') {
    throw 'VFS lock acquisition no longer uses compare-and-exchange ownership'
}
if ($src -match '(?s)fn\s+vfs_lock_acquire\(id,\s*spin_budget\).*?sw\(p,\s*tag\)') {
    throw 'VFS lock acquired by store/steal instead of cmpxchg'
}
if ($src -match '(?i)steal.{0,80}return\s+1') {
    throw 'VFS lock appears to contain a successful lock-steal path'
}
if ($src -notmatch '(?s)fn\s+vfs_lock_release\(id\).*?if\s+lw\(p\)\s*!=\s*tag\s*\{.*?return\s+0;.*?\}.*?sw\(p,\s*0\);') {
    throw 'VFS release no longer owner-checks before clearing the lock'
}
if ($src -notmatch '(?s)fn\s+vfs_lock_acquire\(id,\s*spin_budget\).*?blk_held_push\(p\)') {
    throw 'VFS lock acquisition is not registered for explicit BSP recovery'
}
if ($src -notmatch '(?s)fn\s+vfs_lock_release\(id\).*?blk_held_pop\(p\)') {
    throw 'VFS lock release is not removed from the recovery registry'
}

Write-Host 'VFS lock: PASS (bounded wait, cmpxchg ownership, no steal, owner-checked release).' -ForegroundColor Green
