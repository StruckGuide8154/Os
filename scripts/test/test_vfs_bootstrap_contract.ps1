# Compile/security gate for cold VFS root bootstrap.

$ErrorActionPreference = 'Stop'
$Root = Resolve-Path (Join-Path $PSScriptRoot '..\..')
$Compiler = Join-Path $Root 'src\user\grithl\compiler\gritc.py'
$Source = Join-Path $Root 'src\kernel\grithlk\vfs_bootstrap.ghl'
$Lib = Join-Path $Root 'src\user\grithl\lib'
$OutDir = Join-Path $Root 'build\test-vfs'
$Asm = Join-Path $OutDir 'vfs_bootstrap.asm'
$Safety = Join-Path $OutDir 'vfs_bootstrap.safety.json'

New-Item -Path $OutDir -ItemType Directory -Force | Out-Null
Write-Host 'VFS bootstrap: compiling fail-atomic read-only root bootstrap...' -ForegroundColor Yellow
& python $Compiler $Source -o $Asm -L $Lib --embed --target kernel --forbid-asm --safety-manifest $Safety
if ($LASTEXITCODE -ne 0) { throw 'vfs_bootstrap.ghl failed GritHLK compilation' }

$m = Get-Content -Raw -Path $Safety | ConvertFrom-Json
$declared = @($m.unsafe.declared | ForEach-Object { if ($null -ne $_.cap) { [string]$_.cap } else { [string]$_ } } | Sort-Object)
$expected = @('implicit_extern','raw_mem')
if (($declared -join ',') -ne ($expected -join ',')) {
    throw "VFS bootstrap unsafe surface drifted: [$($declared -join ', ')]"
}
if (@($m.unsafe.privileged).Count -ne 0) { throw 'VFS bootstrap gained privileged unsafe authority' }

$src = Get-Content -Raw -Path $Source
if ($src -notmatch 'const\s+VFS_ROOT_RO_RIGHTS\s*=\s*0x041B;') {
    throw 'Bootstrap root rights are no longer the read-only capability set'
}
if ($src -match 'VFS_R_(WRITE|CREATE|MKDIR|DELETE|RENAME|SYNC)') {
    throw 'Bootstrap source introduced a named mutating root right'
}
if ($src -notmatch '(?s)fn\s+vfs_bootstrap_cold_init\(\).*?if\s+lq\(&vfs_boot_state_v\)\s*!=\s*VFS_BOOT_COLD\s*\{\s*return\s+0;') {
    throw 'Bootstrap no longer rejects repeated initialization'
}
if ($src -notmatch '(?s)fn\s+vfs_bootstrap_cold_init\(\).*?vfs_lock_init\(\).*?vfs_objects_reset\(\).*?vfs_node_alloc.*?vfs_file_alloc.*?while\s+slot\s*<\s*VFS_APP_SLOTS') {
    throw 'Bootstrap initialization ordering drifted'
}
if ($src -notmatch '(?s)fn\s+vfs_bootstrap_fail\(root_file,\s*root_node,\s*initialized_slots\).*?vfs_ctx_reset_slot.*?vfs_file_close.*?vfs_node_free.*?VFS_BOOT_FAILED') {
    throw 'Bootstrap rollback no longer unwinds contexts/root pin/root node'
}
if ($src -match '(?m)^\s*unsafe\s+(asm|raw_io|syscall|user_mem|kernel_priv|kernel_io)\b') {
    throw 'Bootstrap gained authority beyond module-owned state'
}

Write-Host 'VFS bootstrap: PASS (read-only root, one-shot init, fail-atomic rollback).' -ForegroundColor Green
