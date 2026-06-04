%ifndef SYSCALL_USER_INC
%define SYSCALL_USER_INC

%include "app_sysno.inc"

; ============================================================================
; NexusOS v3.0 - Usermode Syscall Wrappers
; ============================================================================

%macro SYS_PRINT 1
    APP_SYSNO 0
    mov rdi, %1
    syscall
%endmacro

%macro SYS_EXIT 0
    APP_SYSNO 1
    syscall
%endmacro

%macro SYS_GUI_RECT 5
    APP_SYSNO 2
    mov rdi, %1
    mov rsi, %2
    mov rdx, %3
    mov r10, %4
    mov r8, %5
    syscall
%endmacro

%macro SYS_GUI_TEXT 5
    APP_SYSNO 3
    mov rdi, %1
    mov rsi, %2
    mov rdx, %3
    mov r10, %4
    mov r8, %5
    syscall
%endmacro

%macro SYS_FS_COUNT 0
    APP_SYSNO 4
    syscall
%endmacro

; SYS_FS_ENTRY(index) -> rax = opaque dir-entry handle (HANDLE_KIND_DIR_ENTRY)
;   index is the valid-entry index in the current directory (skipping volume
;   label / LFN / deleted slots), as enumerated by SYS_FS_COUNT.
;
;   On success rax is a packed 32-bit handle (magic|kind|gen|index) that:
;     * is opaque to ring 3 — DO NOT dereference it. The kernel no longer
;       returns a pointer; the snapshot cache that used to back this call
;       has been removed.
;     * is owned by the calling slot. Closing the slot drops every handle;
;       another slot can never resolve it.
;     * must be paired with SYS_HANDLE_CLOSE when no longer needed (the
;       per-slot table is 64 entries — leaking handles eventually wedges
;       SYS_FS_ENTRY at the alloc step).
;
;   To read fields out of the entry (name, size, attr, first cluster) call
;   SYS_FS_ENTRY_INFO with the handle and a 20-byte user buffer. To act on
;   the entry (read/format/delete/rename/open) pass the handle directly to
;   the matching FS syscall — those resolve through the handle table.
;
;   rax = 0 on any failure (out-of-range index, table full, kernel skip).
%macro SYS_FS_ENTRY 1
    APP_SYSNO 5
    mov rdi, %1
    syscall
%endmacro

%macro SYS_APP_DONE 0
    APP_SYSNO 10
    syscall
%endmacro

%macro SYS_FS_CHDIR 1
    APP_SYSNO 6
    mov rdi, %1
    syscall
%endmacro

%macro SYS_WM_CREATE 6
    APP_SYSNO 7
    mov rdi, %1
    mov rsi, %2
    mov rdx, %3
    mov r10, %4
    mov r8, %5
    mov r9, %6
    syscall
%endmacro

%macro SYS_FS_READ 3
    APP_SYSNO 8
    mov rdi, %1
    mov rsi, %2
    mov rdx, %3
    syscall
%endmacro

%macro SYS_WM_HANDLERS 3
    APP_SYSNO 9
    mov rdi, %1
    mov rsi, %2
    mov rdx, %3
    syscall
%endmacro

%macro SYS_FS_FORMAT_NAME 2
    APP_SYSNO 11
    mov rdi, %1
    mov rsi, %2
    syscall
%endmacro

%macro SYS_APP_LAUNCH 1
    APP_SYSNO 12
    mov rdi, %1
    syscall
%endmacro

%macro SYS_FS_WRITE 3
    APP_SYSNO 13
    mov rdi, %1
    mov rsi, %2
    mov rdx, %3
    syscall
%endmacro

%macro SYS_FS_SYNC_ROOT 0
    APP_SYSNO 14
    syscall
%endmacro

%macro SYS_WM_CLOSE 1
    APP_SYSNO 15
    mov rdi, %1
    syscall
%endmacro

%macro SYS_DISPLAY_SET_MODE 3
    APP_SYSNO 16
    mov rdi, %1
    mov rsi, %2
    mov rdx, %3
    syscall
%endmacro

%macro SYS_CURSOR_INIT 0
    APP_SYSNO 17
    syscall
%endmacro

%macro SYS_TICKS 0
    APP_SYSNO 18
    syscall
%endmacro

%macro SYS_FS_DELETE 1
    APP_SYSNO 19
    mov rdi, %1
    syscall
%endmacro

%macro SYS_FS_RENAME 2
    APP_SYSNO 20
    mov rdi, %1
    mov rsi, %2
    syscall
%endmacro

%macro SYS_FS_MKDIR 1
    APP_SYSNO 21
    mov rdi, %1
    syscall
%endmacro

; SYS_OPEN_FILE_NP(dir_entry_handle) — kernel-side: launch notepad and load file
;   rdi = slot-cached dir entry pointer (from SYS_FS_ENTRY)
;   returns rax = notepad window id, or -1
%macro SYS_OPEN_FILE_NP 1
    APP_SYSNO 22
    mov rdi, %1
    syscall
%endmacro

; SYS_APP_OPEN(command_line)
;   command_line format: "app" or "app param1,param2"
;   returns rax = launched window id, or -1
%macro SYS_APP_OPEN 1
    APP_SYSNO 23
    mov rdi, %1
    syscall
%endmacro

; SYS_DISPLAY_FLAGS()
;   returns bit0=VSync, bit1=FPS overlay, bit2=Stretch.
;   Stretch is plumbed today; display_flip will honor it once the
;   compositor scaler lands. Persisting it through this syscall lets
;   Settings expose the toggle ahead of the scaler work.
%macro SYS_DISPLAY_FLAGS 0
    APP_SYSNO 24
    syscall
%endmacro

; SYS_DISPLAY_SET_FLAGS(flags)
;   bit0=VSync, bit1=FPS overlay, bit2=Stretch. See SYS_DISPLAY_FLAGS.
%macro SYS_DISPLAY_SET_FLAGS 1
    APP_SYSNO 25
    mov rdi, %1
    syscall
%endmacro

; SYS_DESKTOP_BG()
;   returns current desktop background theme id:
;     0=liquid metal, 1=glass ribbons, 2=frosted bloom
%macro SYS_DESKTOP_BG 0
    APP_SYSNO 26
    syscall
%endmacro

; SYS_DESKTOP_SET_BG(theme)
;   theme: 0=liquid metal, 1=glass ribbons, 2=frosted bloom
%macro SYS_DESKTOP_SET_BG 1
    APP_SYSNO 27
    mov rdi, %1
    syscall
%endmacro

; SYS_DISPLAY_NATIVE()
;   returns the monitor's native (boot-time) framebuffer dimensions packed
;   as: width in bits[31:0], height in bits[63:32]. This is the size the
;   UEFI loader picked from GOP — display_set_mode can change scr_width /
;   scr_height after boot, but the value returned here never moves, so it
;   is the right thing to offer as "Use native resolution".
%macro SYS_DISPLAY_NATIVE 0
    APP_SYSNO 28
    syscall
%endmacro

; SYS_DISPLAY_SIZE()
;   returns the current desktop size, same packing as SYS_DISPLAY_NATIVE.
;   Drifts when display_set_mode succeeds; reads should be per-draw.
%macro SYS_DISPLAY_SIZE 0
    APP_SYSNO 29
    syscall
%endmacro

; SYS_XML_PARSE(buf, len) -> rax = 1 ok, 0 err
%macro SYS_XML_PARSE 2
    APP_SYSNO 30
    mov rdi, %1
    mov rsi, %2
    syscall
%endmacro

%macro SYS_XML_ROOT 0
    APP_SYSNO 31
    syscall
%endmacro

%macro SYS_XML_TAG 1
    APP_SYSNO 32
    mov rdi, %1
    syscall
%endmacro

%macro SYS_XML_TAG_NAME 3
    APP_SYSNO 33
    mov rdi, %1
    mov rsi, %2
    mov rdx, %3
    syscall
%endmacro

%macro SYS_XML_FIRST_CHILD 1
    APP_SYSNO 34
    mov rdi, %1
    syscall
%endmacro

%macro SYS_XML_NEXT_SIBLING 1
    APP_SYSNO 35
    mov rdi, %1
    syscall
%endmacro

%macro SYS_XML_PARENT 1
    APP_SYSNO 36
    mov rdi, %1
    syscall
%endmacro

%macro SYS_XML_ATTR 5
    APP_SYSNO 37
    mov rdi, %1
    mov rsi, %2
    mov rdx, %3
    mov r10, %4
    mov r8,  %5
    syscall
%endmacro

%macro SYS_XML_TEXT 3
    APP_SYSNO 38
    mov rdi, %1
    mov rsi, %2
    mov rdx, %3
    syscall
%endmacro

%macro SYS_XML_FREE 0
    APP_SYSNO 39
    syscall
%endmacro

; SYS_DRAW_LINE(x0,y0,x1,y1,color)
%macro SYS_DRAW_LINE 5
    APP_SYSNO 40
    mov rdi, %1
    mov rsi, %2
    mov rdx, %3
    mov r10, %4
    mov r8,  %5
    syscall
%endmacro

; SYS_FILL_CIRCLE(cx,cy,r,color)
%macro SYS_FILL_CIRCLE 4
    APP_SYSNO 41
    mov rdi, %1
    mov rsi, %2
    mov rdx, %3
    mov r10, %4
    syscall
%endmacro

; SYS_FILL_TRIANGLE(coords_ptr, color) — coords_ptr -> 6 int32 [x0,y0,x1,y1,x2,y2]
%macro SYS_FILL_TRIANGLE 2
    APP_SYSNO 42
    mov rdi, %1
    mov rsi, %2
    syscall
%endmacro

; SYS_XML_LAST_ERROR() -> rax bits[31:0]=error, bits[63:32]=byte offset
%macro SYS_XML_LAST_ERROR 0
    APP_SYSNO 43
    syscall
%endmacro

; SYS_XML_NODE_COUNT() -> rax = total parsed DOM nodes
%macro SYS_XML_NODE_COUNT 0
    APP_SYSNO 44
    syscall
%endmacro

; SYS_BLEND_PIXEL(x, y, argb)
%macro SYS_BLEND_PIXEL 3
    APP_SYSNO 45
    mov rdi, %1
    mov rsi, %2
    mov rdx, %3
    syscall
%endmacro

; SYS_BLEND_SPAN(x, y, len, argb)
%macro SYS_BLEND_SPAN 4
    APP_SYSNO 46
    mov rdi, %1
    mov rsi, %2
    mov rdx, %3
    mov r10, %4
    syscall
%endmacro

; SYS_XML_TEXT_RUNS(node) -> rax = mixed-content text run count
%macro SYS_XML_TEXT_RUNS 1
    APP_SYSNO 47
    mov rdi, %1
    syscall
%endmacro

; SYS_XML_TEXT_RUN(node, index, out, max) -> rax = bytes copied
%macro SYS_XML_TEXT_RUN 4
    APP_SYSNO 48
    mov rdi, %1
    mov rsi, %2
    mov rdx, %3
    mov r10, %4
    syscall
%endmacro

; SYS_XML_NAMESPACE(node, prefix, prefix_len, out, max) -> rax = URI length
%macro SYS_XML_NAMESPACE 5
    APP_SYSNO 49
    mov rdi, %1
    mov rsi, %2
    mov rdx, %3
    mov r10, %4
    mov r8,  %5
    syscall
%endmacro

; SYS_XML_NODE_NAMESPACE(node, out, max) -> rax = URI length
%macro SYS_XML_NODE_NAMESPACE 3
    APP_SYSNO 50
    mov rdi, %1
    mov rsi, %2
    mov rdx, %3
    syscall
%endmacro

; SYS_XML_ENTITY_VALUE(name, name_len, out, max) -> rax = bytes copied
%macro SYS_XML_ENTITY_VALUE 4
    APP_SYSNO 51
    mov rdi, %1
    mov rsi, %2
    mov rdx, %3
    mov r10, %4
    syscall
%endmacro

; SYS_BLEND_SPAN_ARGB(x, y, len, buf)
%macro SYS_BLEND_SPAN_ARGB 4
    APP_SYSNO 52
    mov rdi, %1
    mov rsi, %2
    mov rdx, %3
    mov r10, %4
    syscall
%endmacro

; SYS_BLEND_SPAN_ARGB_SCREEN(x, y, len, buf)
%macro SYS_BLEND_SPAN_ARGB_SCREEN 4
    APP_SYSNO 53
    mov rdi, %1
    mov rsi, %2
    mov rdx, %3
    mov r10, %4
    syscall
%endmacro

; SYS_BLEND_SPAN_ARGB_MULTIPLY(x, y, len, buf)
%macro SYS_BLEND_SPAN_ARGB_MULTIPLY 4
    APP_SYSNO 54
    mov rdi, %1
    mov rsi, %2
    mov rdx, %3
    mov r10, %4
    syscall
%endmacro

; SYS_SYSINFO(selector, arg)
%macro SYS_SYSINFO 2
    APP_SYSNO 55
    mov rdi, %1
    mov rsi, %2
    syscall
%endmacro

; SYS_NET_PING4(ip)
;   ip = A.B.C.D packed into a 32-bit scalar (8.8.8.8 => 0x08080808)
;   returns approximate RTT in ms, or -1 after a 2s timeout/failure.
%macro SYS_NET_PING4 1
    APP_SYSNO 56
    mov rdi, %1
    syscall
%endmacro

; SYS_NET_TCP_CONNECT4(ip, dst_port, src_port)
;   ip = A.B.C.D packed into a 32-bit scalar
;   returns 1 if a TCP SYN was sent, 0 on network failure, -2 if busy.
%macro SYS_NET_TCP_CONNECT4 3
    APP_SYSNO 60
    mov rdi, %1
    mov rsi, %2
    mov rdx, %3
    syscall
%endmacro

; SYS_NET_DNS_A(hostname)
;   hostname = app-owned C-string such as "example.com"
;   returns IPv4 A.B.C.D packed into a 32-bit scalar, 0 on lookup failure,
;   -1 for invalid arguments, or -2 if another DNS query is in flight.
%macro SYS_NET_DNS_A 1
    APP_SYSNO 61
    mov rdi, %1
    syscall
%endmacro

; SYS_NET_PING4_TICK(ip)
;   Async, non-blocking ICMP echo. Call repeatedly each frame until the
;   return value is non-zero. The kernel runs the ARP+ICMP state machine
;   one short step per call, so the GUI keeps drawing in between.
;   returns:
;     > 0  -> RTT in microseconds (one echo completed)
;     0    -> still in flight, call again next frame
;     -1   -> timeout / no link / send failed
;     -2   -> a ping with a different target is still in flight
%macro SYS_NET_PING4_TICK 1
    APP_SYSNO 62
    mov rdi, %1
    syscall
%endmacro

; SYS_DESKTOP_BG_BUSY()
;   returns 1 while a selected wallpaper is invalid, rendering, or waiting to
;   be presented; 0 once the finished cache has been shown.
%macro SYS_DESKTOP_BG_BUSY 0
    APP_SYSNO 63
    syscall
%endmacro

; SYS_OPEN_FILE_MEDIA(dir_entry_handle) — kernel-side: launch Media Player
;   and load the file's bytes into the new window's slot at
;   APP_SLOT_BMP_FILE_OFF. The Media Player draw fn (app_media_draw) probes
;   the file's magic on every frame and dispatches to the matching codec.
;   rdi = slot-cached dir entry pointer (from SYS_FS_ENTRY)
;   returns rax = media window id, or -1
%macro SYS_OPEN_FILE_MEDIA 1
    APP_SYSNO 64
    mov rdi, %1
    syscall
%endmacro

; SYS_WM_SET_USER_ARG(win_id, value)
;   Writes a 64-bit opaque value into the target window's WIN_OFF_USER_ARG
;   field. Used by a window's *creator* to pass a small bit of context to a
;   freshly created window whose drawfn will run in a different app slot
;   (e.g. Explorer → Properties window: pass the file-row index).
; SYS_MEDIA_BLIT_SCALED(win_id, src_bgra, packed_dims, reserve_bottom_px, alpha_key)
;   Secure aspect-preserving nearest-neighbor blit of a user-supplied BGRA
;   buffer into the client area of the named window.
;
;   packed_dims = (src_w << 16) | src_h, each half ∈ [1, 4096]. Packed so
;   the syscall fits NexusHL's 6-argument syscall() arity.
;
;   The kernel-side stub validates that:
;     * src_w, src_h ∈ [1, 4096]
;     * src_w * src_h * 4 ≤ 64 MB
;     * src_ptr+byte_len lies entirely in the caller's slot or user blob
;     * win_id < MAX_WINDOWS
;     * reserve_bottom_px is clamped to scr_height
;     * alpha_key reduced to {0,1}
;   Returns 0 on success, -1 on any rejection.
;   Designed for the Media Player codecs (NIC/NBA/BMP-via-scratch/SVG-via-
;   svg2) so the per-codec draw fn can stay in user-mode NexusHL.
%macro SYS_MEDIA_BLIT_SCALED 5
    APP_SYSNO 66
    mov rdi, %1
    mov rsi, %2
    mov rdx, %3
    mov r10, %4
    mov r8,  %5
    syscall
%endmacro

%macro SYS_WM_SET_USER_ARG 2
    APP_SYSNO 65
    mov rdi, %1
    mov rsi, %2
    syscall
%endmacro

; SYS_WX_INSTALL_MANIFEST(code_start_off, code_end_off)
;   Commits this slot's W^X manifest. Both bounds are byte offsets into the
;   slot (NOT addresses) and must be 4KB-aligned and lie inside
;   [L3_APP_CODE_OFF, L3_SHADOW_WIN_OFF) with code_start < code_end. On
;   success the kernel re-applies l3_apply_wx_policy immediately, so:
;     * pages inside [code_start_off, code_end_off) become X+!W
;     * every other slot page becomes W+NX
;   Returns 0 on success, -1 on validation failure.
;   Idempotent — callable any time the app wants to widen/replace its code
;   range. RWX is never produced at any intermediate step.
%macro SYS_WX_INSTALL_MANIFEST 2
    APP_SYSNO 67
    mov rdi, %1
    mov rsi, %2
    syscall
%endmacro

; SYS_MPROTECT_WX(page_addr, mode)
;   Flips a single 4KB page between W+NX (mode 0 = MPROT_WX_MODE_WNX) and
;   X+!W (mode 1 = MPROT_WX_MODE_XRO). Pre-conditions:
;     * SYS_WX_INSTALL_MANIFEST has been called this session.
;     * page_addr is 4KB-aligned.
;     * page_addr lies inside the calling slot.
;     * page_addr's slot-relative offset lies in the installed code range.
;   The PTE transition is two-step (W=0+NX=1 intermediate, with invlpg
;   between) so no TLB cache line ever observes RWX.
;   Returns 0 on success, -1 on any validation failure.
%macro SYS_MPROTECT_WX 2
    APP_SYSNO 68
    mov rdi, %1
    mov rsi, %2
    syscall
%endmacro

; SYS_WX_JIT_ALIAS(x_va, w_alias_va, length)
;   Installs a writable alias of an executable range at a separate VA so a
;   JIT can write generated code via the W alias and execute it via the
;   X mapping without ever holding RWX on the same VA. Pre-conditions:
;     * SYS_WX_INSTALL_MANIFEST has been called this session.
;     * length > 0, page-multiple.
;     * x_va, w_alias_va are 4KB-aligned and lie inside the calling slot.
;     * [x_va, x_va+length)  lies fully inside the installed code range.
;     * [w_alias_va, w_alias_va+length) lies fully OUTSIDE the code range,
;       inside the slot, and every target PTE is currently present (the
;       alias overwrites those PTEs' physical frame mappings).
;   On success each w_alias_va+i*4096 PTE is rewritten to point at the same
;   physical frame as x_va+i*4096 but with W+NX, while the X mapping
;   retains its X+!W permissions. The alias persists for the slot's
;   lifetime; slot teardown tears the PT down.
;   Returns 0 on success, -1 on any validation failure.
%macro SYS_WX_JIT_ALIAS 3
    APP_SYSNO 69
    mov rdi, %1
    mov rsi, %2
    mov rdx, %3
    syscall
%endmacro

; SYS_HANDLE_CLOSE(handle) -> rax = 0 on success, -1 on bad handle
;   Releases an opaque handle previously returned by SYS_FS_ENTRY (or any
;   future handle-returning syscall). The handle is verified against the
;   per-slot table first — a stale or forged handle returns -1 without
;   touching kernel state. After close the entry's generation is bumped
;   on the next reuse, so the closed handle resolves as invalid forever.
;
;   Today only HANDLE_KIND_DIR_ENTRY is allocated, so close() rejects any
;   handle whose kind tag is something else. When future kinds (XML node,
;   net socket, window) migrate onto the table, this syscall will dispatch
;   on the embedded kind tag rather than growing per-kind close syscalls.
%macro SYS_HANDLE_CLOSE 1
    APP_SYSNO 70
    mov rdi, %1
    syscall
%endmacro

; SYS_FS_ENTRY_INFO(handle, out_buf, out_buf_len) -> rax = 0 ok, -1 fail
;   Copies a 20-byte fixed-layout snapshot of the named FAT16 entry into
;   out_buf. out_buf_len must be >= 20. The snapshot is taken at call time;
;   if another writer mutates the entry afterwards the values diverge until
;   the next call. Returns -1 on invalid handle, out-of-range buffer, or
;   undersized buffer.
;
;   Layout (matches the standard FAT16 short-entry head; offsets in bytes):
;       0  u8[8]  name        (space-padded, raw)
;       8  u8[3]  ext         (space-padded, raw)
;      11  u8     attr        (0x10 = directory, 0x08 = vol label, ...)
;      12  u16    first_cluster_lo
;      14  u16    reserved (0)
;      16  u32    size_bytes
;
;   This replaces the previous "SYS_FS_ENTRY returns a snapshot pointer you
;   dereference directly" contract — kernel VAs no longer leak to ring 3.
%macro SYS_FS_ENTRY_INFO 3
    APP_SYSNO 71
    mov rdi, %1
    mov rsi, %2
    mov rdx, %3
    syscall
%endmacro

; Size of the SYS_FS_ENTRY_INFO output struct. Apps that allocate the buffer
; statically should use this so a layout bump shows up at build time.
SYS_FS_ENTRY_INFO_SIZE equ 20

; Manifest version-1 / mode constants mirror boot_memory.inc.
%ifndef MPROT_WX_MODE_WNX
MPROT_WX_MODE_WNX equ 0
MPROT_WX_MODE_XRO equ 1
%endif

; SYS_APP_DECLARE_MANIFEST(app_id) — opt the calling slot into sandboxing.
;   AND-narrows this slot's capability mask to the static manifest declared
;   for app_id in src/include/syscall_caps.inc. After this call, any syscall
;   outside the manifest returns -1 without invoking its handler.
;
;   Call this once, as early as possible in the app's entry point (before
;   any handler that might touch attacker-controlled input). The narrowing
;   is one-way: a second call for a *different* app_id can only remove caps
;   further, never restore them.
;
;   Returns: rax = the effective mask after narrowing, or -1 on bad app_id.
%macro SYS_APP_DECLARE_MANIFEST 1
    APP_SYSNO 72
    mov rdi, %1
    syscall
%endmacro

; SYS_WM_GET_USER_ARG(win_id) -> rax = 48-bit value (zero-extended) or -1.
;   Tag-verified read of WIN_OFF_USER_ARG. The kernel stamps a per-window
;   16-bit tag (derived from kernel_canary) into the high bits on the
;   matching SET; this getter strips and verifies it. A stored zero is
;   returned as 0 (the "never set" sentinel). Apps that previously read the
;   field by dereferencing &window+160 must migrate to this syscall — direct
;   reads now see the tag bytes and won't decode the original value.
%macro SYS_WM_GET_USER_ARG 1
    APP_SYSNO 73
    mov rdi, %1
    syscall
%endmacro

%endif
