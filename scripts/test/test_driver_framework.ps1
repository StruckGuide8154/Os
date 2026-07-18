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
$compiler = Read-RepoFile 'src\user\grithl\compiler\gritc.py'
$driverBlob = Read-RepoFile 'src\drivers\driver_blob.asm'
$slotInstall = Read-RepoFile 'src\kernel\proc\usermode_slot_install.inc'
$translate = Read-RepoFile 'src\kernel\grithlk\usermode_translate.ghl'
$callbacks = Read-RepoFile 'src\kernel\grithlk\usermode_callbacks.ghl'
$syscallData = Read-RepoFile 'src\kernel\proc\syscall_data.inc'
$syscallPerm = Read-RepoFile 'src\kernel\proc\syscall_perm.inc'
$syscallDispatch = Read-RepoFile 'src\kernel\proc\syscall_dispatch_core.inc'
$netCore = Read-RepoFile 'src\user\grithl\lib\core.ghl'
$netApp = Read-RepoFile 'src\user\grithl\apps\ping.ghl'
$netNic = Read-RepoFile 'src\kernel\net\nic.asm'
$netHandlers = Read-RepoFile 'src\kernel\proc\syscall_handlers_wx_net.inc'
$driverLoader = Read-RepoFile 'src\kernel\grithlk\driver_loader.ghl'
$isr = Read-RepoFile 'src\kernel\core\isr.asm'

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

# --- Stage 4b foundation: dedicated driver blob + slot install --------------
Assert-Match $uefiBuild '--embed --target driver --safety-manifest' 'UEFI build does not compile the driver under the non-overridable driver target.'
Assert-Match $compiler 'getattr\(cg,"target","user"\)=="driver"[\s\S]{0,100}mov eax' 'Driver syscalls are not emitted as raw u32 immediates.'
Assert-Match $driverBlob '\[section \.driverblob follows=\.appdata align=4096\]' 'Driver package is not isolated in its own contiguous section.'
Assert-Match $driverBlob 'driver_blob_done_trampoline:[\s\S]{0,100}mov eax, 10[\s\S]{0,50}syscall' 'Driver package lacks a raw app-done return trampoline.'
Assert-Match $driverBlob 'driver_blob_end - driver_blob_start\) >= L3_SLOT_DMA_OFF[\s\S]*%error "ring-3 driver blob reaches the fixed DMA VA window"' 'Driver package lacks a build-time DMA-overlap size assertion.'
Assert-Match $slotInstall 'DRIVER_BLOB_INSTALL_FN[\s\S]*cmp rcx, L3_SLOT_DMA_OFF[\s\S]*l3_slot_blob_kind[\s\S]*l3_wx_code_end[\s\S]*DRIVER_BLOB_INSTALL_FN l3_copy_driver_blob_to_slot' 'Dedicated driver install does not bound the blob below DMA and publish W^X metadata.'
Assert-Match $slotInstall 'l3_copy_driver_blob_to_slot[\s\S]*sc_slot_perm_committed[\s\S]*mov byte \[rax \+ r9\], 0' 'Driver install does not force identity syscall dispatch.'
Assert-Match $translate 'target >= &driver_blob_start[\s\S]*l3_slot_blob_kind[\s\S]*target - &driver_blob_start' 'Canonical driver entries are not kind-gated and translated into the live slot.'
Assert-Match $callbacks 'l3_slot_blob_kind[\s\S]*driver_blob_done_trampoline' 'Callback return does not select the driver-local app-done trampoline.'
Assert-Match $kernelBuild '%include\s+"src/drivers/driver_blob\.asm"' 'Kernel image does not embed the dedicated signed driver package.'
Assert-Match $driverBlob 'driver2_blob_start:[\s\S]*%include "build/ghl/battery\.asm"[\s\S]*driver2_blob_end:' 'Battery is not framed as a second dedicated driver package.'
Assert-NoMatch $driverBlob '\[section \.driverblob2' 'Battery package escaped the single W^X-safe driverblob section.'
Assert-Match $slotInstall 'DRIVER_BLOB_INSTALL_FN l3_copy_driver_blob2_to_slot[^\r\n]*driver2_blob_code_end, 2' 'Battery package has no kind-2 slot installer.'
Assert-Match $driverLoader 'fn\s+battery_init[\s\S]*drvhost_policy_install\(BATTERY_SLOT,\s*DRV_CAP_PIO[\s\S]*drvhost_grant_pio\(id,\s*0x62,\s*0x66\)[\s\S]*call_app_l3_driver\(BATTERY_SLOT,\s*&app_hl_battery_main\)' 'Battery is not provisioned as a PIO-only ring-3 process.'
Assert-NoMatch $kernelBuild 'src/kernel/drivers/battery\.asm' 'Retired in-kernel battery driver is still linked.'

# Driver-host rows extend the syscall table past 255. Ordinary app syscall
# permutations therefore need u16 cells; u8 cells alias rows 256+ onto 0..7.
Assert-Match $syscallData 'sc_slot_perm_inv:\s+times \(MAX_WINDOWS \* syscall_table_count\) dw 0' 'Inverse syscall permutation cells are not wide enough for driver-host rows 256+.'
Assert-Match $syscallData 'sc_slot_perm_fwd:\s+times \(MAX_WINDOWS \* syscall_table_count\) dw 0' 'Forward syscall permutation cells are not wide enough for driver-host rows 256+.'
Assert-Match $syscallPerm 'movzx eax, word \[r8 \+ rdx\*2\]' 'App syscall fixups truncate a u16 permuted syscall number.'
Assert-Match $syscallDispatch 'movzx eax, word \[rdx \+ rcx\*2\]' 'Syscall dispatch truncates the u16 inverse permutation row.'
Assert-Match $netCore 'const\s+NI_DRIVER\s*=\s*10' 'Userspace cannot query the selected network backend.'
Assert-Match $netNic 'cmp rdi, 10\s*; NI_DRIVER[\s\S]{0,100}mov eax, ebx' 'NI_DRIVER does not return the selected backend id.'
Assert-Match $netHandlers 'cmp rdi, 10\s*je \.ni_driver[\s\S]{0,200}\.ni_driver:\s*call net_info' 'SYS_NET_INFO rejects NI_DRIVER before backend dispatch.'
Assert-Match $netApp 'driver == NET_NIC_VIRTIO\s*\{ return &link_virtio; \}' 'Networking app does not identify the active VirtIO backend.'
Assert-Match $netNic 'net_ping4_tick:[\s\S]{0,250}cmp eax, NET_NIC_VIRTIO[\s\S]{0,100}jmp net_ping_l2_tick' 'Async ping is not routed to the generic VirtIO ICMP state machine.'
Assert-Match (Read-RepoFile 'src\kernel\grithlk\ip.ghl') 'fn\s+net_ping_l2_tick[\s\S]*NET_IP_PROTO_ICMP[\s\S]*net_ping_l2_rx_ipv4' 'Generic VirtIO ICMP TX/RX path is missing.'
Assert-Match (Read-RepoFile 'src\kernel\grithlk\ip.ghl') 'fn\s+ip_checksum[\s\S]*let ck = ip_checksum\(&net_ping_l2_packet, 16\)' 'VirtIO ping must not call the legacy rdi/ecx checksum through the System-V expression ABI.'

Assert-Match $classes 'DEVCLASS_ABI_VERSION' 'Device-class ABI version is missing.'
Assert-Match $classes 'DEVCLASS_NET_L2\s+equ\s+1' 'net.l2 class id changed.'
Assert-Match $classes 'DEVCLASS_WLAN_RADIO\s+equ\s+8' 'wlan.radio class id changed.'
Assert-Match $classes 'DEVMSG_HEADER_SIZE\s+equ\s+40' 'Common device message header size changed.'
Assert-Match $classes 'DEVRING_DESC_SIZE\s+equ\s+32' 'Common device ring descriptor size changed.'

# --- Stage 4a: driver-facing DMA self-service + bounded IRQ wait ------------
# The ONE driver-callable DMA path is policy-bounded self-service, never a raw
# grant from ring 3. GRANT_DMA(234)/DMA_MAP(242)/IRQ_WAIT(243) must be live rows
# (no longer denied stubs) and CAP_DRIVER-gated.
$bootmem = Read-RepoFile 'src\include\boot_memory.inc'
$driverDma = Read-RepoFile 'src\kernel\proc\usermode_driver_dma.inc'

Assert-Match $broker 'data\s+drv_slot_policy_dma_cap:\s*16\s*x\s*8' 'Per-driver signed DMA cap table is missing.'
Assert-Match $broker 'fn\s+drvhost_policy_install\(slot,\s*caps,\s*code_hash,\s*dma_cap\)' 'policy_install did not gain the dma_cap parameter.'
Assert-Match $broker 'fn\s+drvhost_dma_alloc\(id,\s*len\)' 'Policy-bounded DMA self-service allocator is missing.'
Assert-Match $broker 'if\s+drv_has_cap\(id,\s*DRV_CAP_DMA\)\s*==\s*0\s*\{\s*return\s+0' 'DMA alloc does not require signed CAP_DMA.'
Assert-Match $broker 'if\s+total\s*>\s*cap\s*\{\s*return\s+0' 'DMA alloc does not enforce the signed dma_cap ceiling.'
Assert-Match $broker 'page_alloc_contig\(pages\)' 'DMA alloc does not allocate coherent frames from the broker (driver could mint DMA).'
Assert-Match $broker 'fn\s+drvhost_dma_map\(id,\s*phys\)' 'DMA map primitive is missing.'
Assert-Match $broker 'l3_map_driver_dma\(id\s*-\s*1,\s*phys,\s*len\)' 'DMA map does not delegate PTE writes to the paging TCB helper.'
Assert-Match $broker 'fn\s+drvhost_irq_note\(vector\)' 'Forwarded-IRQ pending producer is missing.'
Assert-Match $broker 'fn\s+drvhost_irq_take\(id\)' 'Forwarded-IRQ pending drain is missing.'
Assert-Match $broker 'l3_unmap_driver_dma\(id\s*-\s*1\)' 'Quarantine/revoke does not tear down the driver DMA VA mapping.'

# The DMA VA window must be disjoint from the handle table (assert lives in the header).
Assert-Match $bootmem 'L3_SLOT_DMA_OFF\s+equ' 'Per-slot DMA VA window offset is missing.'
Assert-Match $bootmem 'driver DMA window overlaps the handle table' 'DMA-window/handle-table disjointness assert is missing.'
Assert-Match $driverDma 'or\s+rax,\s*rbx\s*;\s*\+\s*NX' 'DMA window PTEs are not forced non-executable (NX).'
Assert-Match $driverDma 'cmp\s+rax,\s*L3_SLOT_DMA_OFF\s*[\r\n]\s*ja\s+\.mdd_fail' 'DMA map does not fail-closed when the code blob would reach the DMA window.'

# Syscall rows: 234/242/243 are live handlers, still CAP_DRIVER-gated, and the
# ring-3 handlers still never call a control-plane grant/policy primitive.
Assert-Match $table 'sc_drvhost_dma_alloc[^\r\n]*SC_KIND1\(FN_KIND_SCALAR\)[^\r\n]*CAP_DRIVER' 'GRANT_DMA(234) is not wired to the policy-bounded allocator.'
Assert-Match $table 'sc_drvhost_dma_map[^\r\n]*SC_KIND1\(FN_KIND_SCALAR\)[^\r\n]*CAP_DRIVER' 'DMA_MAP(242) is still a denied stub.'
Assert-Match $table 'sc_drvhost_irq_wait[^\r\n]*CAP_DRIVER' 'IRQ_WAIT(243) is still a denied stub.'
Assert-Match $handlers 'call\s+drvhost_dma_alloc' 'DMA alloc handler does not reach the broker allocator.'
Assert-Match $handlers 'call\s+drvhost_dma_map' 'DMA map handler does not reach the broker.'
Assert-Match $handlers 'call\s+drvhost_irq_take[\s\S]{0,400}hlt' 'IRQ_WAIT is not a bounded yielding wait on the pending word.'

# G4 executable proof: forged out-of-grant request cannot reach raw hardware;
# repeated abuse quarantines/revokes; recovery is separate and grantless.
$g4Eval = Join-Path $Root 'scripts\test\eval_drvhost_quarantine.py'
& python $g4Eval
if ($LASTEXITCODE -ne 0) { throw 'Track-8 G4 quarantine/restart proof failed.' }
& python $g4Eval --selftest
if ($LASTEXITCODE -ne 0) { throw 'Track-8 G4 planted-broken-broker selftest failed.' }
$classEval = Join-Path $Root 'scripts\test\eval_drvclass_handles.py'
& python $classEval
if ($LASTEXITCODE -ne 0) { throw 'Track-8 class-handle proof failed.' }
& python $classEval --selftest
if ($LASTEXITCODE -ne 0) { throw 'Track-8 planted stale-handle selftest failed.' }
Assert-Match $handlers 'call\s+drvhost_charge_result' 'Rejected driver syscalls are not charged to the fault budget.'
Assert-Match $isr 'l3_slot_blob_kind[\s\S]{0,300}call\s+drvhost_fault' 'A crashing ring-3 driver is not charged by the exception unwind.'
Assert-Match $driverLoader 'fn\s+driver_manager_recover[\s\S]*drvhost_restart\(id\)[\s\S]*driver_manager_bind_authority' 'VirtIO quarantine recovery is not a separate policy-derived loader path.'
Assert-Match $driverLoader 'fn\s+battery_recover[\s\S]*drvhost_restart\(id\)[\s\S]*drvhost_grant_pio\(id,\s*0x62,\s*0x66\)' 'Battery quarantine recovery does not reconstruct its narrow PIO grant.'
Assert-Match $broker 'fn\s+drvclass_resolve[\s\S]*drvclass_generation[\s\S]*drv_restarts' 'Class handles are not resolved against kernel-owned generation state.'
Assert-Match $broker 'fn\s+drvhost_revoke_resources[\s\S]*drvclass_revoke\(id\)' 'Quarantine does not revoke published class endpoints.'
Assert-Match $driverLoader 'drvclass_publish_net_l2\(id,[\s\S]{0,200}1500, 0\)[\s\S]{0,200}driver_manager_bound' 'net.l2 is not health-gated before publication.'
Assert-Match $driverLoader 'fn\s+driver_manager_tx_frame[\s\S]*drvclass_resolve\(class_handle, DRVCLASS_NET_L2, DRVCLASS_ABI_V1\)' 'net.l2 TX does not validate its generation-safe class handle.'

Write-Host '[driver-framework] PASS' -ForegroundColor Green
