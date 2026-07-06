; ============================================================================
; Grit v3.0 - System Constants
; ============================================================================

%include "boot_memory.inc"

; --- Memory Layout ---
; Cache32Max speed tiers:
; - L1-hot: IRQ/syscall/scheduler/input flags/per-core state.
; - L2-warm: HID parser, window metadata, font/text primitives, FAT metadata.
; - L3/LLC GUI: framebuffer composition buffers in 4MB..16MB.
; - RAM-cold: app arenas, device DMA rings, filesystem staging, debug data.
; Core physical addresses live in boot_memory.inc.
; IDT is 256*16 = 4KB. If stack grows down from 2MB, IDT at 2MB grows up?
; IDT structure is fixed size.
; If Stack Top is 0x200000, IDT at 0x200000 overlaps stack top!
; Stack grows DOWN. IDT grows UP (fixed size).
; If IDT is at 0x200000, it occupies 0x200000 to 0x201000.
; If Stack starts at 0x200000, a push writes to 0x1FFFF8.
; So they don't overlap. This is safe.

%ifdef GRIT_CACHE32_MAX
CACHE32_RAM_LIMIT   equ 0x2000000    ; 32MB strict profile cap
SYSTEM_RESERVED_END equ (BOOT_ANIM_BUF_ADDR + BOOT_ANIM_BUF_SIZE)
SMP_CORE_STATE_ADDR equ 0xC40000     ; Cacheline-aligned per-core records
SMP_CORE_STACK_BASE equ 0xC50000     ; AP stacks grow down from here
SMP_MAX_CORES       equ 8
SMP_CORE_STATE_SIZE equ 128
SMP_CORE_STACK_SIZE equ 0x4000
%elifdef GRIT_SMP
SMP_CORE_STATE_ADDR equ 0xC40000
SMP_CORE_STACK_BASE equ 0xC50000
SMP_MAX_CORES       equ 8
SMP_CORE_STATE_SIZE equ 128
SMP_CORE_STACK_SIZE equ 0x4000
SYSTEM_RESERVED_END equ (BOOT_ANIM_BUF_ADDR + BOOT_ANIM_BUF_SIZE)
%else
SMP_CORE_STATE_ADDR equ 0xC40000
SMP_MAX_CORES       equ 1
SMP_CORE_STATE_SIZE equ 128
SYSTEM_RESERVED_END equ (BOOT_ANIM_BUF_ADDR + BOOT_ANIM_BUF_SIZE)
%endif

; Per-core state record field offsets (record is SMP_CORE_STATE_SIZE bytes).
; NOTE: offsets +24..+79 are OWNED by the SMP CPU-accounting fields published by
; smp_worker_loop / cpu_acct (workqueue.ghl, cpu_acct.ghl):
;   +0  dword  state (3 = PARKED/available, counted by smp_count_states)
;   +4  dword  dense core index
;   +8  dword  LAPIC id
;   +16 qword  liveness beat / heartbeat
;   +24 dword  utilisation percent  (CS_UTIL / SCS_UTIL)
;   +28 dword  clock MHz estimate   (CS_MHZ  / SCS_MHZ)
;   +32 qword  busy-cycle accumulator
;   +40 qword  idle-cycle accumulator
;   +48 qword  last TSC mark
;   +56 qword  last published tick
;   +64 qword  last IA32_APERF snapshot
;   +72 qword  last IA32_MPERF snapshot
;   +80 qword  this CPU's read-back IA32_PAT (AP_STATE_OFF_PAT) - written by
;              ap_long_mode_init right after the PAT wrmsr so the BSP can emit
;              every core's PAT and a test can assert the WC layout is uniform.
;              MUST live above +79: smp_worker_loop writes CS_MHZ at +28 the
;              instant an AP enters the worker (before any PIT-tick window), so
;              parking PAT in the +24/+28 dwords had its high half overwritten by
;              the (then-zero) MHz estimate -> recorded PAT read back as
;              0000000000070106. The live MSR was always correct; only the
;              recorded copy collided. Slot +80 is unused by every other writer.
AP_STATE_OFF_PAT    equ 80

; --- Media player per-window full-clip buffer ------------------------------
; Upper bound on a single video's contiguous buffer (page_alloc_contig). Caps
; how much physical RAM one media window can claim for a clip larger than its
; 256 KiB slot buffer; clips above this play truncated rather than refusing.
MEDIA_FULL_BUF_MAX_SZ equ 0x4000000   ; 64 MiB

; --- SMP process-manager core policy ---------------------------------------
; Cores 0 and 1 are reserved for "system" work: the BSP render loop, drivers,
; GUI, and high-priority kernel jobs. App processes default to the complement
; mask so user code never preempts system work. An app may broaden or narrow
; its mask via SYS_PROC_SET_AFFINITY (Stage 2+); the kernel still rejects any
; bit that would land an app on a system core.
SMP_SYSTEM_CORE_MASK equ 0x00000003   ; bit 0 = core 0, bit 1 = core 1
SMP_APP_CORE_MASK    equ 0xFFFFFFFC   ; complement; masked against ncores at use

; --- Process pool layout (shared by proc/process.asm and workqueue.asm) -----
MAX_PROCESSES        equ 12
PROCESS_POOL         equ 0xC30000     ; 12 * 512 bytes

; --- Priority manager (Stage 0): scheduling priority classes ----------------
; Windows-style numeric priority. Higher value = scheduled first. The
; priority-aware process_schedule picks the highest-priority READY process and
; round-robins within a level. PRIO_IDLE is the demotion floor for a slot that
; blew its CPU budget (Stage 1 demote-then-kill). PRIO_REALTIME requires an
; explicit capability at SYS_PROC_SETPRIO time (cannot be reached by clamp).
PRIO_IDLE            equ 0            ; demotion floor for over-budget offenders
PRIO_LOW             equ 4
PRIO_NORMAL          equ 8            ; default class for a freshly created app
PRIO_HIGH            equ 16
PRIO_KERNEL          equ 24           ; PID 0 (kernel main loop)
PRIO_REALTIME        equ 31           ; cap-gated ceiling
PRIO_MIN             equ PRIO_IDLE
PRIO_MAX             equ PRIO_REALTIME
; Time-slice length in PIT ticks per priority class (Stage 2 honours this; Stage
; 0/1 only store it). ~100 Hz PIT, so NORMAL ~= 50 ms.
QUANTUM_TICKS_NORMAL equ 5
QUANTUM_TICKS_HIGH   equ 8
; Demote-then-kill: strikes before a sustained over-budget slot is TERMINATED.
PRIO_STRIKES_TO_KILL equ 3

; --- Stage 2 disk layout ---
STAGE2_SECTORS      equ 63           ; Sectors 1-63
KERNEL_START_SECTOR equ 64           ; Kernel starts at sector 64
KERNEL_SECTORS      equ 4096         ; 2MB max BIOS-loaded kernel
FAT16_PART_LBA      equ (KERNEL_START_SECTOR + KERNEL_SECTORS)

; Largest sector count any single ata_read_sectors / ata_write_sectors call may
; request. The block layer trusts the caller-supplied count for the destination
; window (it cannot see the buffer size), and it also feeds the ramdisk region
; classifier. A wild/hostile count therefore drives either an unbounded PIO loop
; or (via ramdisk_classify's range add) a 32-bit wrap that mis-passes the region
; gate. This fail-closed ceiling bounds every call to the largest provisioned
; FS cache (fat16_fat_cache / fat16_file_buf = 65536 B = 128 sectors in
; fat16_core.ghl); floor_store passes 1, the FAT/root/cluster caches ≤128. A
; request above this cap is a bug or an attack -> rejected, never truncated.
ATA_MAX_SECTORS_PER_CALL equ 128
%if (ATA_MAX_SECTORS_PER_CALL * 512) > DATA_IMG_MAX_SIZE
%error "ATA_MAX_SECTORS_PER_CALL: a single capped transfer can exceed the ramdisk window"
%endif

; --- Screen ---
SCREEN_WIDTH        equ 1024
SCREEN_HEIGHT       equ 768
SCREEN_BPP          equ 32
SCREEN_PITCH        equ (SCREEN_WIDTH * 4)   ; 4096 bytes per scanline
FRAMEBUFFER_SIZE    equ (SCREEN_WIDTH * SCREEN_HEIGHT * 4)  ; 3145728 = ~3MB


; VBE info offsets live in boot_memory.inc.

; --- Colors (32-bit 0x00RRGGBB, stored as BGRX in memory) ---
; Grit design-system light palette semantic tokens.
COLOR_BG_BASE       equ 0x00F5F6FA   ; #F5F6FA
COLOR_SURFACE_1     equ 0x00FFFFFF   ; #FFFFFF
COLOR_SURFACE_2     equ 0x00ECEFF4   ; #ECEFF4
COLOR_BORDER        equ 0x00D8DDE3   ; #D8DDE3
COLOR_BORDER_STRONG equ 0x00C4CBD3   ; #C4CBD3
COLOR_TEXT_PRIMARY  equ 0x000F141E   ; #0F141E
COLOR_TEXT_SECONDARY equ 0x004B5563  ; #4B5563
COLOR_TEXT_TERTIARY equ 0x008A939F   ; #8A939F
COLOR_ACCENT_LIGHT  equ 0x004C8BFF   ; #4C8BFF
COLOR_ACCENT        equ 0x002A6FFF   ; #2A6FFF
COLOR_ACCENT_DARK   equ 0x001A55D6   ; #1A55D6
COLOR_CYAN          equ 0x0036C0E0   ; #36C0E0
COLOR_CYAN_DARK     equ 0x001291B0   ; #1291B0
COLOR_ERROR         equ 0x00E5474D   ; #E5474D
COLOR_WARNING       equ 0x00F7B52C   ; #F7B52C
COLOR_SUCCESS       equ 0x002EB56E   ; #2EB56E

COLOR_BLACK         equ 0x00000000
COLOR_WHITE         equ 0x00FFFFFF
COLOR_DESKTOP_BG    equ COLOR_BG_BASE
COLOR_TASKBAR_BG    equ COLOR_SURFACE_2
COLOR_TASKBAR_TOP   equ COLOR_SURFACE_1
COLOR_CHROME_FACE   equ COLOR_SURFACE_2
COLOR_SURFACE       equ COLOR_SURFACE_1
COLOR_SUNKEN        equ COLOR_SURFACE_2
COLOR_BEVEL_LT      equ COLOR_SURFACE_1
COLOR_BEVEL_DK      equ COLOR_BORDER_STRONG
COLOR_BEVEL_XDK     equ COLOR_BORDER
COLOR_TITLEBAR      equ COLOR_ACCENT
COLOR_TITLEBAR_UNF  equ COLOR_BORDER_STRONG
COLOR_WINDOW_BG     equ COLOR_SURFACE_1
COLOR_WINDOW_BORDER equ COLOR_BORDER
COLOR_CLOSE_BTN     equ COLOR_ERROR
COLOR_CLOSE_HOVER   equ 0x00F2666C
COLOR_MIN_BTN       equ COLOR_SURFACE_2
COLOR_TEXT_WHITE     equ COLOR_WHITE
COLOR_TEXT_BLACK     equ COLOR_TEXT_PRIMARY
COLOR_TEXT_GRAY      equ COLOR_TEXT_SECONDARY
COLOR_TEXT_TITLE     equ COLOR_WHITE
COLOR_HIGHLIGHT      equ COLOR_ACCENT
COLOR_CURSOR         equ COLOR_TEXT_PRIMARY
COLOR_START_BTN      equ COLOR_SURFACE_1
COLOR_START_HOVER    equ COLOR_SURFACE_2

; --- Grit Design System geometry / elevation / glass tokens ---
; (spacing.css). Single source of truth for the kernel chrome renderer.
; Corner radii (px) - soft, never razor-sharp.
DS_R_XS             equ 5     ; chips, tiny controls
DS_R_SM             equ 7     ; buttons, inputs
DS_R_MD             equ 9     ; menus, small cards
DS_R_LG             equ 13    ; cards, panels
DS_R_XL             equ 16    ; windows, dialogs
DS_R_2XL            equ 22    ; dock, hero surfaces
; Control / chrome sizing.
DS_CTL_H_SM         equ 28
DS_CTL_H_MD         equ 34
DS_CTL_H_LG         equ 42
DS_TITLEBAR_H       equ 40
DS_DOCK_H           equ 64
; Glass: titlebar/dock/menu backdrop blur radius + translucent tint.
; Tint stored as 0xAARRGGBB (alpha-premultiply at composite time).
DS_BLUR_GLASS       equ 22    ; px backdrop blur radius (--blur-glass)
DS_BLUR_THIN        equ 12    ; px (--blur-thin)
DS_GLASS_TINT       equ 0xA816181D   ; rgba(22,24,29,0.66) -> A=0xA8
DS_GLASS_TINT_2     equ 0xBC1C1F25   ; rgba(28,31,37,0.74) -> A=0xBC
; Inner top lit edge (--edge-light): white @ ~5% over dark.
DS_EDGE_LIGHT       equ 0x0DFFFFFF   ; A=0x0D (~5%)
; Drop-shadow: opacity (0..255) packed; geometry used by draw_drop_shadow.
; --shadow-window ~ large soft; --shadow-md ~ medium.
DS_SHADOW_WIN_A     equ 0x9E   ; ~0.62 alpha
DS_SHADOW_WIN_BLUR  equ 28
DS_SHADOW_WIN_DY    equ 18
DS_SHADOW_MD_A      equ 0x61   ; ~0.38 alpha
DS_SHADOW_MD_BLUR   equ 12
DS_SHADOW_MD_DY     equ 5
; Motion durations (ms) + easing ids (--dur-*, --ease-*).
DS_DUR_1            equ 90
DS_DUR_2            equ 150
DS_DUR_3            equ 240
DS_DUR_4            equ 400
DS_EASE_OUT         equ 0
DS_EASE_IN_OUT      equ 1
DS_EASE_SPRING      equ 2

; --- Syscall rate limiting (security_todo.md §2) ---
; Per-slot token bucket size, refilled by pit_handler every timer tick. At the
; PIT tick rate this caps a slot to SC_BUDGET_PER_TICK * tick_rate syscalls/sec
; - far below the millions a fuzzer/side-channel oracle needs, yet generous for
; legitimate GUI apps. Stored as a word per slot (slot_sc_budget in syscall.asm)
; so values up to 65535 are valid. 4096/tick @100Hz ~= 409600 calls/s ceiling.
SC_BUDGET_PER_TICK  equ 4096
; GUI syscalls use a separate frame/tick bucket so rendering does not drain the
; general syscall budget, but is still bounded.
SC_GUI_BUDGET_PER_TICK equ 8192

; --- No-progress / spin watchdog (FE/FH spam class of bug) ---
; A slot that issues the SAME syscall with the SAME (arg0,arg1) this many times
; in a row - making no observable progress (e.g. SYS_FS_ENTRY(0) -> 0 forever) -
; is flagged with a structured serial diagnostic instead of spinning silently.
; Picked well above any legitimate same-arg poll burst within a tick, but far
; below the rate-limit ceiling so a wedged loop is caught long before the budget
; throttle masks it. Debug-only (ENABLE_DEBUG_SERIAL); zero-cost in release.
SC_PROGRESS_LIMIT   equ 1024

; --- Wallpaper-render isolation watchdog ---
; wallpaper_render_active gates the ENTIRE interactive path: the window
; compositor (window_desktop.inc), the taskbar / start-menu / context-menu draw
; (frame_present.ghl), and crucially dispatch_app_callback (callback_dispatch.ghl)
; which drops every app click/draw callback while it is set. The flag is cleared
; only when the AP wallpaper render job finishes - and that job runs the ring-3
; SVG draw with NO deadman guard. So a wedged/runaway wallpaper render (a tenant
; spinning in usermode) would pin the flag at 1 and freeze the whole UI: drag
; releases don't commit, apps/menus won't open, the bg never lands.
;
; This is the hard bound, measured in tick_count units (the 100 Hz PIT counter,
; NOT frames - while the render is active the BSP busy-repaints far above the
; idle 30 Hz governor, so a frame/poll count would abandon a legit render early).
; If a render stays active longer than this, the kernel ABANDONS it - clears
; wallpaper_render_active, reverts to the solid desktop, and lets the slot's
; normal strike/deadman engine reclaim the runaway AP. One app can no longer
; freeze every other app via the background. Generous: a full-quality SVG raster
; finishes in well under 20 s; this only fires on a genuinely stuck render.
WALLPAPER_RENDER_MAX_TICKS equ 2000        ; 100 Hz -> ~20 s

; --- Per-core raster target (GS-base relative) ---
; The raster destination (addr/width/height/pitch) is per-CPU: each core's GS
; base points at its own RTGT_STRIDE-byte slot in raster_target_tbl, so the BSP
; compositor (core 0, targeting the back buffer) and an AP wallpaper render
; (targeting the packed wallpaper cache) never share the pointer. This is what
; lets the compositor / taskbar / window drag stay live while the wallpaper
; rasterizes on an AP, instead of being frozen by the old wallpaper_render_active
; gate. Fields are read in the hot per-pixel primitives as [gs:RTGT_*], so the
; lookup is a single segment-relative load (no wd_core_index in the pixel loop).
; raster_gs_init seeds every core's slot with the same back-buffer default the
; old global raster_target_* had, so a raster op on a core that has not yet run a
; target-select still writes somewhere safe rather than to a null slot.
RTGT_ADDR    equ 0          ; qword: destination base
RTGT_WIDTH   equ 8          ; dword: clip width  (px)
RTGT_HEIGHT  equ 12         ; dword: clip height (px)
RTGT_PITCH   equ 16         ; qword: row pitch   (bytes)
RTGT_STRIDE  equ 32         ; per-core slot stride (padded)
IA32_GS_BASE_MSR equ 0xC0000101

; --- Slot teardown on suspect syscall return (security_todo.md §12) ---
; Number of security-reason -1 returns (cap mismatch, validator reject, rate
; reject) a single slot may accumulate before the dispatcher auto-kills it and
; writes an audit entry. Rejections are otherwise silent and cost-free for an
; attacker; capping them turns repeated probing into a self-terminating slot.
; Stored as a word per slot (slot_sc_strikes in syscall.asm). Set comfortably
; above the handful of benign rejects a legitimate app may trigger (e.g. a
; closed-handle race) but well below a fuzzing run.
SC_STRIKE_LIMIT     equ 16

; --- Behavioral anomaly detector (security_todo.md §11) ---
; The dispatcher keeps an always-on per-slot syscall histogram (syscall_trace.inc);
; sc_anomaly_scan_all walks it on a coarse pit cadence and flags a slot whose
; syscall MIX deviates from its app-class profile - e.g. a Notepad slot suddenly
; hammering the W^X / JIT-alias surface. Because the histogram is bumped at
; dispatch entry (before the cap gate), it counts *attempts*, so a sandboxed app
; probing a forbidden high-risk syscall shows up even though every call is
; cap-rejected. On a flag the detector drives the slot through the existing
; §12 strike path (sc_record_strike), so repeated/excessive high-risk behaviour
; throttles toward the same SC_STRIKE_LIMIT slot-kill - no new teardown path.
;
; ANOMALY_SCAN_PERIOD: scan cadence in PIT ticks (power of two so pit_handler
; masks it with AND, like CODE_HASH_VERIFY_PERIOD). Coarser than the rate-limit
; refill so the per-tick cost stays negligible.
ANOMALY_SCAN_PERIOD equ 128
; High-risk syscall budget per scan window for a slot WITHOUT the matching cap.
; A slot that lacks CAP_WX has an expected W^X-syscall rate of zero, so even a
; couple of attempts in a scan window is a real behavioral anomaly; allow a tiny
; slack for a benign mis-call before charging a strike.
ANOMALY_HIRISK_DENY_BUDGET  equ 2
; High-risk syscall budget per scan window for a slot that legitimately HOLDS
; the cap (e.g. a real JIT app granted CAP_WX). It may use the surface, but a
; flood far above any sane JIT warm-up is still throttled. Generous headroom.
ANOMALY_HIRISK_HOLD_BUDGET  equ 256

; --- Window Manager ---
MAX_WINDOWS         equ APP_SLOT_COUNT
WINDOW_STRUCT_SIZE  equ 256          ; Bytes per window struct
; SYS_WM_LIST record: u32 id, u32 flags, 40-byte title (null-padded). Kept in
; sync with the WM_LIST_REC const in core.ghl and the shell's taskbar reader.
WM_LIST_REC         equ 48
WM_LIST_TITLE_OFF   equ 8
WM_LIST_TITLE_LEN   equ 40
L3_USER_STACK_SIZE  equ 16384        ; 16 KB user stack per L3 window callback context
L3_SYSCALL_STACK_SIZE equ 4096       ; 4 KB usable syscall stack per L3 context
; Per-slot footprint in l3_syscall_stacks (16 KiB stride, two guard pages):
;   +0x0000  guard page      (PAGE_PRESENT cleared)
;   +0x1000  shadow stack    (4 KiB, parallel return-addr mirror; see
;                             src/include/shadow_stack.inc)
;   +0x2000  guard page      (PAGE_PRESENT cleared)
;   +0x3000  syscall stack   (4 KiB usable; RSP_top = base + (i+1)*STRIDE)
; Both guards are punched by l3_install_syscall_stack_pt. The syscall stack
; occupies the top 4 KiB; an overflow off its bottom faults into the +0x2000
; guard. The shadow address for any syscall-stack slot is (rsp ^ 0x2000) -
; the stride is 16 KiB-aligned so that XOR maps the live stack page to its
; mirror page without leaving the slot.
L3_SYSCALL_STACK_STRIDE equ 16384
TITLEBAR_HEIGHT     equ 24
BORDER_WIDTH        equ 2
CLOSE_BTN_SIZE      equ 18
MIN_BTN_SIZE        equ 18
MIN_WINDOW_W        equ 200
MIN_WINDOW_H        equ 100

; --- Taskbar ---
; Only size constants live here. Y positions and right-anchored X
; positions depend on the current screen size and are kept in runtime
; globals owned by display.asm (scr_taskbar_y, scr_clock_x, ...). The
; kernel recomputes them in display_recompute_layout() whenever a mode
; change happens, so the taskbar follows the active resolution.
TASKBAR_HEIGHT      equ 36
START_BTN_W         equ 70
START_BTN_H         equ 28
START_BTN_X         equ 4
CLOCK_WIDTH         equ 64

; --- Keyboard ---
KB_BUFFER_SIZE      equ 64

; --- Mouse ---
MOUSE_BUFFER_SIZE   equ 64
CURSOR_WIDTH        equ 12
CURSOR_HEIGHT       equ 19

; --- PIT ---
PIT_FREQUENCY       equ 100          ; 100Hz = 10ms per tick
PIT_DIVISOR         equ 11932        ; 1193182 / 100

; --- PIC vectors ---
IRQ_BASE_MASTER     equ 32
IRQ_BASE_SLAVE      equ 40
IRQ_TIMER           equ 32           ; IRQ0 -> vector 32
IRQ_KEYBOARD        equ 33           ; IRQ1 -> vector 33
IRQ_CASCADE         equ 34           ; IRQ2 -> vector 34
IRQ_MOUSE           equ 44           ; IRQ12 -> vector 44

; --- Font ---
FONT_WIDTH          equ 8
FONT_HEIGHT         equ 16
FONT_FIRST_CHAR     equ 32           ; Space
FONT_LAST_CHAR      equ 126          ; Tilde
FONT_NUM_CHARS      equ 95           ; 126 - 32 + 1

; --- Window flags ---
WF_VISIBLE          equ 0x01
WF_FOCUSED          equ 0x02
WF_DRAGGING         equ 0x04
WF_MINIMIZED        equ 0x08
WF_ACTIVE           equ 0x10         ; Slot is in use
WF_MANIFEST_OK      equ 0x20         ; Capability manifest has been applied to this
                                     ; slot. Cleared at create (struct is zeroed),
                                     ; set by kernel_apply_app_manifest. Until set,
                                     ; sc_record_strike suppresses strikes so a draw
                                     ; dispatched in the launch gap (window drawable
                                     ; before its manifest narrows caps) cannot kill
                                     ; the app for the kernel's own ordering race.
WF_READY            equ 0x40         ; Window is FULLY provisioned and safe to
                                     ; render: capability manifest applied, L3 slot
                                     ; seeded, and the CPI-signed click/key/draw
                                     ; handlers installed. Cleared at create (struct
                                     ; is zeroed); set as the LAST launch step by
                                     ; wm_window_finalize (and immediately for
                                     ; app-created SYS_WM_CREATE windows, which are
                                     ; provisioned by their already-sandboxed
                                     ; caller). wm_draw_window refuses to render a
                                     ; window without it, so the launch-ordering
                                     ; race -- window drawable before its manifest /
                                     ; slot-seed land -- can never present a blank
                                     ; frame or dispatch a draw whose syscalls the
                                     ; cap gate then rejects. The authoritative
                                     ; "drawable" gate; WF_VISIBLE remains the
                                     ; user-facing show/hide (minimize, taskbar).
WF_SHELL            equ 0x80         ; This window IS the ring-3 desktop shell
                                     ; (gshell.ghl, APP_SHELL slot): chromeless,
                                     ; full-screen, drawn UNDER all app windows as
                                     ; the desktop layer, and excluded from
                                     ; wm_hit_window_at / SYS_WM_LIST. Empty-area
                                     ; clicks that miss every app window route to
                                     ; its client click handler (the taskbar /
                                     ; desktop / Start menu live in gshell). Set as
                                     ; the post-launch step in .launch_shell; the
                                     ; shell is never WF_FOCUSED so the focused
                                     ; draw pass never lifts it over apps. Replaces
                                     ; the retired kernel asm shell (desktop.asm +
                                     ; taskbar.asm). See docs/shell-architecture.md.

; --- Mouse event types ---
MEVT_MOVE           equ 1
MEVT_LCLICK         equ 2
MEVT_RCLICK         equ 3
MEVT_LRELEASE       equ 4
MEVT_RRELEASE       equ 5

; --- Key modifier flags ---
KMOD_SHIFT          equ 0x01
KMOD_CTRL           equ 0x02
KMOD_ALT            equ 0x04

; --- Virtual Key Codes (ASCII byte in kb_buffer for non-printable keys) ---
KEY_F1              equ 0xF1
KEY_F2              equ 0xF2
KEY_F3              equ 0xF3
KEY_F4              equ 0xF4
KEY_F5              equ 0xF5
KEY_F6              equ 0xF6
KEY_F7              equ 0xF7
KEY_F8              equ 0xF8
KEY_F9              equ 0xF9
KEY_F10             equ 0xFA
KEY_F11             equ 0xFB
KEY_F12             equ 0xFC

; --- USB/XHCI Memory Layout ---
XHCI_DCBAA_ADDR     equ 0x1900000    ; Device Context Base Address Array
XHCI_CMD_RING_ADDR  equ 0x1910000    ; Command Ring (4096 TRBs)
XHCI_ERST_ADDR      equ 0x1920000    ; Event Ring Segment Table
XHCI_EVT_RING_ADDR  equ 0x1930000    ; Event Ring (4096 TRBs)
XHCI_SCRATCH_ADDR   equ 0x1940000    ; Scratchpad array + buffers
XHCI_DEV_CTX_ADDR   equ 0x1950000    ; Output Device Context (slot 1)
XHCI_INPUT_CTX_ADDR equ 0x1960000    ; Input Context
XHCI_CTRL_RING_ADDR equ 0x1970000    ; Control EP0 Transfer Ring
XHCI_INT_RING_ADDR  equ 0x1980000    ; Interrupt IN Transfer Ring
XHCI_CTRL_BUF_ADDR  equ 0x1990000    ; Control transfer data buffers
XHCI_MOUSE_BUF_ADDR equ 0x19A0000    ; Mouse interrupt data buffers (slot 1)
; Slot 2 device support
XHCI_DEV_CTX2_ADDR  equ 0x19B0000    ; Output Device Context (slot 2)
XHCI_INT_RING2_ADDR equ 0x19C0000    ; Interrupt IN Transfer Ring (slot 2)
XHCI_MOUSE_BUF2_ADDR equ 0x19D0000   ; Mouse interrupt data buffers (slot 2)
XHCI_CTRL_RING2_ADDR equ 0x19E0000   ; Control EP0 Transfer Ring (slot 2)
XHCI_MEM_END        equ 0x19F0000    ; End of XHCI memory region

; Hard ceiling on bytes the controller may DMA into a per-slot HID interrupt
; buffer AND the byte count the parser is allowed to walk. The USB endpoint
; wMaxPacketSize field is 11 bits => spec-legal mps <= 2047 < 0x800, so this
; clamp never fires for a conforming device; it is a fail-closed, defence-in-
; depth bound used at the DMA queue site and the parser call so a malicious or
; future-unmasked usb_ep_mps can never overrun the buffer's slack (the proof of
; memory safety must hold in asm alone, not lean on the GHL `& 0x07FF` mask).
XHCI_HID_REPORT_MAX equ 0x800
; Build-enforce the safety invariant: each slot's interrupt buffer must have at
; least XHCI_HID_REPORT_MAX bytes of slack before the next allocated region, so
; a full-size transfer cannot scribble into the neighbouring xHCI structure.
%if (XHCI_DEV_CTX2_ADDR - XHCI_MOUSE_BUF_ADDR) < XHCI_HID_REPORT_MAX
  %error "XHCI_MOUSE_BUF_ADDR slack < XHCI_HID_REPORT_MAX (slot1 HID buffer too small)"
%endif
%if (XHCI_CTRL_RING2_ADDR - XHCI_MOUSE_BUF2_ADDR) < XHCI_HID_REPORT_MAX
  %error "XHCI_MOUSE_BUF2_ADDR slack < XHCI_HID_REPORT_MAX (slot2 HID buffer too small)"
%endif

; --- xHCI device-supplied index bounds (security) -------------------------
; Both the Enable-Slot completion's slot id and the HCSPARAMS2 scratchpad count
; are attacker-influenced (supplied by the controller) yet used as indices into
; the fixed xHCI DMA region. These constants + asserts pin the cross-region
; invariants that keep every such index in-bounds so the safety proof does not
; silently rest on the memory map happening to be generous.
;
; MaxSlotsEn is programmed to at most 16 (xhci_init CONFIG write), so a conforming
; controller only ever returns a slot id in 1..16. xhci_enable_slot fail-closed
; rejects anything outside 1..XHCI_MAX_SLOT_ID before it indexes DCBAA/doorbell.
XHCI_MAX_SLOT_ID    equ 16
; Largest count of 4 KiB scratchpad buffers that fit AFTER the pointer-array page
; inside the SCRATCH region. Buffers live at XHCI_SCRATCH_ADDR + 0x1000*(i+1), so
; the last buffer (i = count-1) must end at or before the next region (DEV_CTX):
;   0x1000 * (count+1) <= (XHCI_DEV_CTX_ADDR - XHCI_SCRATCH_ADDR)
XHCI_SCRATCH_MAX    equ ((XHCI_DEV_CTX_ADDR - XHCI_SCRATCH_ADDR) / 0x1000) - 1
; A validated slot id (1..XHCI_MAX_SLOT_ID) must index inside the DCBAA region.
%if ((XHCI_MAX_SLOT_ID + 1) * 8) > (XHCI_CMD_RING_ADDR - XHCI_DCBAA_ADDR)
  %error "DCBAA region too small for XHCI_MAX_SLOT_ID entries"
%endif
; Defence in depth: even an UNVALIDATED 8-bit slot id (0..255) stays inside the
; DCBAA region, so a malicious Enable-Slot response can never reach host RAM
; outside the array even in the window before the range check rejects it.
%if ((255 + 1) * 8) > (XHCI_CMD_RING_ADDR - XHCI_DCBAA_ADDR)
  %error "DCBAA region < 256 slot entries (8-bit slot id could escape the array)"
%endif
; The scratchpad region must hold at least one buffer after its pointer page.
%if (XHCI_SCRATCH_MAX < 1)
  %error "SCRATCH region too small for even one scratchpad buffer"
%endif

; --- RTL8152/RTL8156 USB Ethernet DMA region ---
; Kept outside the fixed xHCI controller workspace. The RTL8139 fallback uses
; 0x1B00000..0x1B04800, so USB NIC rings start after that window.
RTL8156_BULK_IN_RING_ADDR  equ 0x1B10000
RTL8156_BULK_OUT_RING_ADDR equ 0x1B20000
RTL8156_RX_BUF_ADDR        equ 0x1B30000
RTL8156_TX_BUF_ADDR        equ 0x1B40000
RTL8156_SCRATCH_ADDR       equ 0x1B50000
; RX DMA window: the bulk-IN TRB writes exactly RTL8156_RX_DMA_LEN bytes into
; the single buffer at RTL8156_RX_BUF_ADDR. The Realtek rx_desc header is 24
; bytes and the frame follows it, so a frame can be at most (DMA_LEN - 24)
; bytes. The device-reported length field (rx_desc opts1, low 15 bits => up to
; 32767) is UNTRUSTED and MUST be clamped to this before it drives a read of
; the frame body — otherwise handle_frame reads stale/unmapped memory past the
; buffer (GSEC G1 OOB; same class as the rtl8139 RX length clamp).
RTL8156_RX_DMA_LEN         equ 4096
RTL8156_RX_DESC_LEN        equ 24
RTL8156_RX_MAX_FRAME       equ (RTL8156_RX_DMA_LEN - RTL8156_RX_DESC_LEN)
; The DMA read must never leave the RX buffer's own region (the next region,
; the TX buffer, starts one 0x10000 slot up). Pin it so the buffer layout and
; the clamp can never silently drift apart.
%if (RTL8156_RX_DMA_LEN > (RTL8156_TX_BUF_ADDR - RTL8156_RX_BUF_ADDR))
  %error "RTL8156 RX DMA window overruns into the TX buffer region"
%endif
; Dedicated xHCI device context + control EP0 ring for the NIC slot, so that
; addressing the NIC does not stomp the HID slot1/slot2 device contexts that
; the mouse/keyboard drivers depend on.
RTL8156_XHCI_DEV_CTX_ADDR  equ 0x1B60000
RTL8156_XHCI_CTRL_RING_ADDR equ 0x1B70000

; --- XHCI Capability Register Offsets (from MMIO base) ---
XHCI_CAP_CAPLENGTH  equ 0x00
XHCI_CAP_HCSPARAMS1 equ 0x04
XHCI_CAP_HCSPARAMS2 equ 0x08
XHCI_CAP_HCCPARAMS1 equ 0x10
XHCI_CAP_DBOFF      equ 0x14
XHCI_CAP_RTSOFF     equ 0x18

; --- XHCI Operational Register Offsets (from OpBase) ---
XHCI_OP_USBCMD      equ 0x00
XHCI_OP_USBSTS      equ 0x04
XHCI_OP_PAGESIZE     equ 0x08
XHCI_OP_DNCTRL      equ 0x14
XHCI_OP_CRCR_LO     equ 0x18
XHCI_OP_CRCR_HI     equ 0x1C
XHCI_OP_DCBAAP_LO   equ 0x30
XHCI_OP_DCBAAP_HI   equ 0x34
XHCI_OP_CONFIG      equ 0x38

; --- XHCI Port Register Offsets (from OpBase + 0x400) ---
XHCI_PORTSC         equ 0x00
XHCI_PORT_REG_SIZE  equ 0x10         ; 16 bytes per port

; --- XHCI Runtime Register Offsets (from RtBase) ---
XHCI_RT_IR0_IMAN    equ 0x20
XHCI_RT_IR0_IMOD    equ 0x24
XHCI_RT_IR0_ERSTSZ  equ 0x28
XHCI_RT_IR0_ERSTBA_LO equ 0x30
XHCI_RT_IR0_ERSTBA_HI equ 0x34
XHCI_RT_IR0_ERDP_LO equ 0x38
XHCI_RT_IR0_ERDP_HI equ 0x3C

; --- USBCMD bits ---
XHCI_CMD_RS         equ (1 << 0)     ; Run/Stop
XHCI_CMD_HCRST      equ (1 << 1)     ; Host Controller Reset
XHCI_CMD_INTE       equ (1 << 2)     ; Interrupter Enable

; --- USBSTS bits ---
XHCI_STS_HCH        equ (1 << 0)     ; HC Halted
XHCI_STS_EINT       equ (1 << 3)     ; Event Interrupt (write-1-to-clear)
XHCI_STS_CNR        equ (1 << 11)    ; Controller Not Ready

; --- PORTSC bits ---
XHCI_PORTSC_CCS     equ (1 << 0)     ; Current Connect Status
XHCI_PORTSC_PED     equ (1 << 1)     ; Port Enabled/Disabled
XHCI_PORTSC_PR      equ (1 << 4)     ; Port Reset
XHCI_PORTSC_PLS_SHIFT equ 5          ; Port Link State shift
XHCI_PORTSC_PP      equ (1 << 9)     ; Port Power
XHCI_PORTSC_SPEED_SHIFT equ 10       ; Port Speed shift
XHCI_PORTSC_CSC     equ (1 << 17)    ; Connect Status Change
XHCI_PORTSC_PRC     equ (1 << 21)    ; Port Reset Change
; Bits that are RW1CS (write 1 to clear) - must preserve when writing other bits
XHCI_PORTSC_CHANGE_BITS equ ((1<<17)|(1<<18)|(1<<20)|(1<<21)|(1<<22)|(1<<23))

; --- TRB Types (shifted into bits 15:10 of dword 3) ---
TRB_NORMAL           equ (1 << 10)
TRB_SETUP            equ (2 << 10)
TRB_DATA             equ (3 << 10)
TRB_STATUS           equ (4 << 10)
TRB_LINK             equ (6 << 10)
TRB_ENABLE_SLOT      equ (9 << 10)
TRB_DISABLE_SLOT     equ (10 << 10)
TRB_ADDRESS_DEV      equ (11 << 10)
TRB_CONFIG_EP        equ (12 << 10)
TRB_EVAL_CTX         equ (13 << 10)
TRB_RESET_ENDPOINT   equ (14 << 10)
TRB_SET_TR_DEQUEUE   equ (16 << 10)
TRB_TRANSFER_EVT     equ (32 << 10)
TRB_CMD_COMPLETION   equ (33 << 10)
TRB_PORT_STATUS_CHG  equ (34 << 10)

; --- TRB Flag Bits (dword 3) ---
TRB_CYCLE            equ (1 << 0)     ; Cycle bit
TRB_TC               equ (1 << 1)     ; Toggle Cycle (Link TRB)
TRB_IOC              equ (1 << 5)     ; Interrupt On Completion
TRB_IDT              equ (1 << 6)     ; Immediate Data
TRB_BSR              equ (1 << 9)     ; Block Set Address Request

; --- TRB Setup stage Transfer Type (bits 17:16 of dword 3) ---
TRB_TRT_NO_DATA      equ (0 << 16)
TRB_TRT_OUT          equ (2 << 16)
TRB_TRT_IN           equ (3 << 16)

; --- TRB Data stage Direction (bit 16 of dword 3) ---
TRB_DIR_OUT          equ (0 << 16)
TRB_DIR_IN           equ (1 << 16)

; --- Ring sizes ---
XHCI_RING_SIZE       equ 4096         ; TRBs per ring (64KB)
XHCI_TRB_SIZE        equ 16           ; Bytes per TRB

; --- USB Standard Request Codes ---
USB_REQ_GET_DESC     equ 0x06
USB_REQ_SET_CONFIG   equ 0x09
USB_REQ_SET_IFACE    equ 0x0B

; --- USB HID Request Codes ---
USB_HID_SET_PROTOCOL equ 0x0B

; --- USB Descriptor Types ---
USB_DESC_DEVICE      equ 0x01
USB_DESC_CONFIG      equ 0x02
USB_DESC_INTERFACE   equ 0x04
USB_DESC_ENDPOINT    equ 0x05
USB_DESC_HID         equ 0x21

; --- USB Endpoint Types ---
USB_EP_CONTROL       equ 0
USB_EP_ISOCH         equ 1
USB_EP_BULK          equ 2
USB_EP_INTERRUPT     equ 3

; --- XHCI Endpoint Types (for Endpoint Context) ---
XHCI_EP_NOT_VALID    equ 0
XHCI_EP_ISOCH_OUT    equ 1
XHCI_EP_BULK_OUT     equ 2
XHCI_EP_INT_OUT      equ 3
XHCI_EP_CONTROL      equ 4
XHCI_EP_ISOCH_IN     equ 5
XHCI_EP_BULK_IN      equ 6
XHCI_EP_INT_IN       equ 7

; --- XHCI Port Speeds ---
XHCI_SPEED_FULL      equ 1
XHCI_SPEED_LOW       equ 2
XHCI_SPEED_HIGH      equ 3
XHCI_SPEED_SUPER     equ 4

; --- gui2 retained-mode command buffer (SYS_GUI_BATCH) ---
; Fixed 64-byte little-endian-quad records: q0=op q1=A q2=B q3=C q4=D q5=E
; q6=F q7=tag(reserved). See syscall_handlers_gui2.inc.
GUI_REC_SIZE         equ 64
GUI_MAX_RECORDS      equ 4096        ; per-batch cap (range = count*64 bytes)
GUI_DAMAGE_RECT_SIZE equ 32          ; SYS_GUI_PRESENT damage rect = 4 quads
GUI_GLYPH_NONE       equ -1          ; SYS_GUI_GLYPH_BAKE "no atlas cell"
; Record opcodes
GUI_OP_NOP           equ 0
GUI_OP_RECT          equ 1           ; A=x B=y C=w D=h E=color
GUI_OP_TEXT          equ 2           ; A=x B=y C=str_ptr D=fg E=bg F=len
GUI_OP_GLYPH         equ 3
GUI_OP_CLIP          equ 4           ; A=x B=y C=w D=h ; C<0 = pop
GUI_OP_BLIT          equ 5
; Record field byte offsets
GUI_REC_OP           equ 0
GUI_REC_A            equ 8
GUI_REC_B            equ 16
GUI_REC_C            equ 24
GUI_REC_D            equ 32
GUI_REC_E            equ 40
GUI_REC_F            equ 48
