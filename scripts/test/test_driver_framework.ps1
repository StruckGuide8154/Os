$ErrorActionPreference = 'Stop'

$Root = Resolve-Path (Join-Path $PSScriptRoot '..\..')

function Read-RepoFile([string]$Path) {
    return Get-Content -LiteralPath (Join-Path $Root $Path) -Raw
}

function Assert-Match([string]$Text, [string]$Pattern, [string]$Message) {
    if ($Text -notmatch $Pattern) { throw $Message }
}

function Assert-NoMatch([string]$Text, [string]$Pattern, [string]$Message) {
    if ($Text -match $Pattern) { throw $Message }
}

$caps = Read-RepoFile 'src\include\syscall_caps.inc'
$table = Read-RepoFile 'src\kernel\proc\syscall_support.inc'
$handlers = Read-RepoFile 'src\kernel\proc\syscall_handlers_wx_net.inc'
$broker = Read-RepoFile 'src\kernel\grithlk\driver_host.ghl'
$classes = Read-RepoFile 'src\include\net_driver.inc'
$kernelBuild = Read-RepoFile 'src\kernel\kernel_build.asm'
$uefiBuild = Read-RepoFile 'scripts\build\build_uefi.ps1'

Assert-Match $caps 'CAP_DRIVER\s+equ\s+0x2000' 'CAP_DRIVER is missing or renumbered.'
Assert-Match $caps 'MANIFEST_DRIVER_BASE\s+equ\s+CAP_CORE\s*\|\s*CAP_DRIVER' 'Driver base manifest is missing.'
Assert-NoMatch $caps 'MANIFEST_(EXPLORER|TERMINAL|NOTEPAD|SETTINGS|PAINT|ABOUT|SECURITY_PROBE|TASKMGR|PING|MEDIA|SHELL)[^\r\n]*CAP_DRIVER' 'An ordinary app manifest gained CAP_DRIVER.'

Assert-Match $table '%rep\s+\(232\s*-\s*81\)' 'Sparse driver ABI no longer begins at syscall 232.'
Assert-Match $table 'sc_drvhost_register[^\r\n]*CAP_DRIVER' 'Driver registration row is not CAP_DRIVER-gated.'
Assert-Match $table 'sc_drvhost_ring_submit[^\r\n]*SC_DESC_LENx\(0,\s*2,\s*SCSZ_16\)[^\r\n]*SC_DESC_WRITE\(0\)[^\r\n]*SC_FLAG_STRICT' 'Ring submit does not validate the complete writable descriptor batch.'

Assert-Match $handlers 'movzx\s+edi,\s*r15b[\s\S]*call\s+drvhost_register_slot' 'Registration does not derive identity from the active slot.'
Assert-NoMatch $handlers 'call\s+drvhost_(grant|policy_install)' 'Ring-3 syscall wrapper exposes a control-plane grant/policy function.'
Assert-NoMatch $handlers 'call\s+drvhost_register\b' 'Ring-3 wrapper bypasses slot-derived registration.'
Assert-Match $handlers 'USER_ACCESS_BEGIN[\s\S]*call\s+drvhost_ring_submit[\s\S]*USER_ACCESS_END' 'Ring submission is not SMAP-bracketed.'

Assert-Match $broker 'data\s+drv_slot_policy_caps:\s*16\s*x\s*4' 'Kernel-owned driver policy table is missing.'
Assert-Match $broker 'fn\s+drvhost_register_slot\(slot,\s*requested\)' 'Slot-derived broker registration is missing.'
Assert-NoMatch $broker '\b(ld|sd)\(' 'Obsolete ld/sd primitives reappeared in the linked broker.'
Assert-Match $broker 'const\s+RING_MAX_DESC\s*=\s*256' 'Driver batch work bound is missing.'
Assert-Match $broker 'if\s+count\s*>\s*RING_MAX_DESC\s*\{\s*return\s+DRV_ERR_GRANT' 'Oversized driver batches are not rejected.'
Assert-Match $broker 'if\s+op\s*!=\s*DESC_OP_WRITE32\s*\{\s*rc\s*=\s*DRV_ERR_GRANT' 'Unknown driver-ring operations are not rejected before execution.'
Assert-Match $broker 'data\s+drv_ring_scratch:\s*65536\s*x\s*1' 'Kernel-owned driver-ring snapshots are missing.'
Assert-Match $broker 'atomic_xchg\(&drv_ring_busy\s*\+\s*id\s*\*\s*4,\s*1\)' 'Per-driver ring serialization is missing.'
Assert-Match $broker 'data\s+drv_pci_cfg_busy:\s*1\s*x\s*4[\s\S]*atomic_xchg\(&drv_pci_cfg_busy,\s*1\)[\s\S]*drvhost_raw_pci_cfg_read32[\s\S]*atomic_xchg\(&drv_pci_cfg_busy,\s*0\)' 'PCI CF8/CFC transactions are not serialized.'
Assert-Match $broker 'let\s+snap\s*=\s*&drv_ring_scratch[\s\S]*sq\(s,\s*lq\(u\)\)[\s\S]*drvhost_raw_mmio_write32\(addr,\s*lw\(s\s*\+\s*8\)\)' 'Ring execution does not use the kernel-owned snapshot.'
Assert-NoMatch $broker 'drvhost_raw_mmio_(read|write)32\([^\r\n]*\bdesc_base\b' 'Hardware execution reloads mutable user descriptors.'
Assert-Match $broker 'if\s+lw\(&drv_state\s*\+\s*id\s*\*\s*4\)\s*!=\s*DRV_ST_NONE\s*\{\s*return\s+DRV_ERR_STATE' 'Driver registration is not one-shot.'
Assert-Match $broker 'fn\s+drvhost_quarantine[\s\S]*drvhost_revoke_resources\(id\)' 'Quarantine does not revoke hardware grants.'
Assert-Match $broker 'fn\s+drvhost_restart[\s\S]*drvhost_revoke_resources\(id\)' 'Restart does not revoke stale hardware grants.'
Assert-Match $kernelBuild '%include\s+"build/ghl/driver_host\.asm"' 'Kernel does not link the driver-host broker.'
Assert-Match $uefiBuild "driver_host\.ghl';\s*out\s*=\s*'build\\ghl\\driver_host\.asm'" 'UEFI generator does not compile driver_host.ghl.'

Assert-Match $classes 'DEVCLASS_ABI_VERSION' 'Device-class ABI version is missing.'
Assert-Match $classes 'DEVCLASS_NET_L2\s+equ\s+1' 'net.l2 class id changed.'
Assert-Match $classes 'DEVCLASS_WLAN_RADIO\s+equ\s+8' 'wlan.radio class id changed.'
Assert-Match $classes 'DEVMSG_HEADER_SIZE\s+equ\s+40' 'Common device message header size changed.'
Assert-Match $classes 'DEVRING_DESC_SIZE\s+equ\s+32' 'Common device ring descriptor size changed.'

Write-Host '[driver-framework] PASS' -ForegroundColor Green
