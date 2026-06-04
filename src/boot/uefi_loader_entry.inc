; ============================================================================
; ENTRY POINT
; RCX = ImageHandle   RDX = SystemTable
; ============================================================================
_start:
    ; Entry RSP = 16n-8.  sub 40 -> 16n-48 = 0 mod 16. Aligned for calls.
    sub rsp, 40
    mov [v_handle], rcx
    mov [v_systab], rdx

    mov rax, [rdx + ST_BOOTSVC]
    mov [v_bs], rax

    ; Disable watchdog (4 args, all zero except handle)
    mov rcx, [v_bs]
    mov rax, [rcx + BS_WATCHDOG]
    xor ecx, ecx
    xor edx, edx
    xor r8d, r8d
    xor r9d, r9d
    call rax

    ; === S0: Claim fixed physical pages for kernel use ===
    call claim_pages

    ; === S1: GOP graphics init ===
    call gop_init
    test rax, rax
    jnz .gop_warn
    jmp .gop_done
.gop_warn:
    mov rdi, VBE_INFO
    xor eax, eax
    mov ecx, 24 / 4
    rep stosd
.gop_done:

    ; === S1.25: Allocate dynamic boot-owned buffers ===
    call alloc_boot_regions

    ; === S1.5: Locate EFI_SIMPLE_POINTER_PROTOCOL and save for kernel ===
    call locate_spp

    ; === S2: Load kernel from filesystem ===
    call load_kernel
    test rax, rax
    jnz .fail_kernel

    ; === S2b: Load APPS.BIN ===
    ; KASLR mode keeps using the embedded app blob. The diff-relocation fixup
    ; table patches that copy along with the rest of the kernel payload; the
    ; standalone APPS.BIN is built at the unslid 0x100000 base and cannot be
    ; reused after a random slide without a second relocation pass.
%ifndef ENABLE_KASLR
    call load_apps
%else
    mov qword [abs VBE_INFO + VBE_APPS_BASE_OFF], 0
    mov qword [abs VBE_INFO + VBE_APPS_SIZE_OFF], 0
%endif

    ; === S2b2: Load DATA.IMG (FAT16 ramdisk for real hardware) ===
    ; Real laptops have no legacy IDE controller, so the kernel's fat16
    ; driver cannot reach a separate data disk. The build script writes
    ; the FAT partition to \EFI\BOOT\DATA.IMG; we slurp it into firmware-
    ; allocated pages and publish (base, size) via VBE_INFO. ata.asm's
    ; ramdisk shim then satisfies fat16 sector I/O from RAM. Non-fatal:
    ; if DATA.IMG is missing the kernel falls back to ATA PIO and simply
    ; finds no usable volume (same as today).
    call load_data_img

    ; === S2b3: Phase 1b - resolve DATA.IMG physical LBA extents on the ESP
    ; via EFI_BLOCK_IO_PROTOCOL while firmware services are still alive.
    ; Captured in VBE_INFO + STORAGE_EXTENTS_ADDR for ramdisk_flush in the
    ; kernel (Phase 5). Non-fatal: failure leaves contract zeroed.
    call resolve_data_img_extents

    ; === S2c: If previous kernel left a klog flush request in RAM, write it
    ; out to \KLOG.TXT and clear the magic. Non-fatal on failure. ===
    call flush_klog_if_pending

    ; === S3: Build identity-mapped page tables ===
    call setup_paging

    ; === S4: Exit boot services ===
    call exit_boot_services
    test rax, rax
    jnz .fail_exit

    cli

    SER 'E'             ; E = ExitBootServices OK

    ; Fix CR4: clear LA57/PCIDE/SMEP/SMAP/PKE, enable PAE+SSE
    mov rax, cr4
    btr rax, 7          ; PGE   off
    btr rax, 12         ; LA57  off
    btr rax, 17         ; PCIDE off
    btr rax, 20         ; SMEP  off
    btr rax, 21         ; SMAP  off
    btr rax, 22         ; PKE   off
    bts rax, 5          ; PAE   on
    bts rax, 9          ; OSFXSR on
    bts rax, 10         ; OSXMMEXCPT on
    mov cr4, rax
    SER 'C'             ; C = CR4 fixed

    ; Fix EFER: set LME and NXE. NXE is required before any PTE uses
    ; PAGE_NX (bit 63); per-slot W^X enforcement (l3_apply_wx_policy)
    ; relies on this. BIOS path mirrors this in stage2.asm.
    mov ecx, 0xC0000080
    rdmsr
    bts eax, 8          ; LME on
    bts eax, 11         ; NXE on (enable NX bit in page tables)
    wrmsr
    SER 'F'             ; F = EFER fixed

    ; Clear CR0.WP so we can write UEFI's read-only 0x100000
    mov rax, cr0
    btr rax, 16
    mov cr0, rax
    SER 'W'             ; W = WP cleared

    ; Copy GDT to 0x500 and trampoline to 0x8000 BEFORE anything
    ; else can corrupt the PE image we're still running from.
    cld
    lea rsi, [gdt64]
    mov rdi, 0x500
    mov rcx, gdt64_end - gdt64
    rep movsb

    lea rsi, [trampoline]
    mov rdi, 0x8000
    mov rcx, (trampoline_end - trampoline + 7) / 8
    rep movsq
    SER 'T'             ; T = GDT + trampoline copied

    ; Load GDT from 0x580 (fixed physical address)
    mov word  [abs 0x580], gdt64_end - gdt64 - 1
    mov qword [abs 0x582], 0x500
    lgdt [abs 0x580]

    ; Far return to reload CS = 0x08
    lea rax, [.cs_reload]
    push qword 0x08
    push rax
    retfq

.cs_reload:
    mov ax, 0x10
    mov ds, ax
    mov es, ax
    mov fs, ax
    mov gs, ax
    mov ss, ax
    SER 'G'             ; G = GDT + segments reloaded

    ; Switch to kernel stack
    mov rsp, KERN_STACK
    SER 'S'             ; S = stack set

    ; === KASLR: parse container header, pick slide, set up trampoline args ===
    ;
    ; Container layout (see tools/build/extract_kaslr_fixups.py):
    ;   0x00 8  magic "NXKASLR0"
    ;   0x08 4  payload_size
    ;   0x0C 4  entry_offset
    ;   0x10 4  fixup_count
    ;   0x14 4  reserved
    ;   0x18 fixup_count*4   fixup_offsets (u32 each, into payload)
    ;   ...  payload_size    raw kernel bytes (assembled at KERNEL_LOAD_ADDR)
    ;
    ; Slide window:
    ;   max_slide = KERNEL_STACK_TOP - STACK_RESERVE - KERNEL_LOAD_ADDR - payload
    ;             = 0xC00000 - 0x40000 - 0x100000 - payload_size
    ;             = 0xAC0000 - payload_size
    ;   Floor-aligned to 4 KiB. 256 KiB stack reserve keeps the kernel stack
    ;   (grows down from 0xC00000) clear of slid kernel text.
    ;
    ; Without ENABLE_KASLR the slide is forced to 0 — runtime layout must
    ; reproduce the legacy "kernel at 0x100000" behavior byte-for-byte.
    mov rsi, [v_kernel_addr]

    mov rax, [rsi]
    mov rbx, 0x3052_4C53_414B_584E   ; "NXKASLR0" little-endian
    cmp rax, rbx
    jne .kaslr_bad_magic

    mov eax, [rsi + 0x08]            ; payload_size
    mov [v_payload_size], rax
    mov eax, [rsi + 0x0C]            ; entry_offset
    mov [v_entry_off], rax
    mov eax, [rsi + 0x10]            ; fixup_count
    mov [v_fixup_count], rax

    lea rbx, [rsi + 0x18]            ; fixup table start
    mov [v_fixup_src], rbx

    mov rax, [v_fixup_count]
    shl rax, 2                       ; *4 bytes per fixup offset
    add rax, rbx                     ; payload start = fixups end
    mov [v_payload_src], rax

%ifdef ENABLE_KASLR
    mov rax, 0xAC0000
    sub rax, [v_payload_size]
    jbe .slide_zero                  ; payload too large for window
    shr rax, 12                      ; max_pages (exclusive upper bound)
    jz  .slide_zero
    mov rbx, rax                     ; rbx = max_pages

    push rbx
    mov eax, 1
    cpuid
    bt  ecx, 30                      ; RDRAND support
    pop rbx
    jnc .slide_rdtsc
    rdrand rax
    jc  .slide_mix
    rdrand rax
    jc  .slide_mix
.slide_rdtsc:
    rdtsc
    shl rdx, 32
    or  rax, rdx
.slide_mix:
    push rax
    rdtsc
    shl rdx, 32
    or  rax, rdx
    pop rcx
    xor rax, rcx
    mov rcx, 0x9E3779B97F4A7C15
    xor rax, rcx
    mov rcx, 0x5851F42D4C957F2D
    mul rcx                          ; LCG multiply (rax = low 64 bits)
    mov rcx, 0x14057B7EF767814F
    add rax, rcx
.slide_have_rand:
    xor edx, edx
    div rbx                          ; rdx = rand mod max_pages
    test rdx, rdx
    jnz .slide_nonzero
    cmp rbx, 1
    jbe .slide_nonzero
    mov edx, 1                       ; keep enabled-KASLR boots visibly slid
.slide_nonzero:
    shl rdx, 12                      ; -> bytes, 4 KiB aligned
    mov [v_kslide], rdx
    jmp .slide_done
.slide_zero:
%endif
    mov qword [v_kslide], 0
.slide_done:

%ifndef RELEASE_BUILD
    ; Serial print "KS=XXXXXXXX " for boot-log triage.
    SER 'K'
    SER 'S'
    SER '='
    mov ebx, [v_kslide]
    mov ecx, 8
.kslide_print_loop:
    rol ebx, 4
    mov al, bl
    and al, 0x0F
    cmp al, 10
    jb  .kslide_digit
    add al, 'A' - 10 - '0'
.kslide_digit:
    add al, '0'
    mov dx, 0x3F8
    out dx, al
    dec ecx
    jnz .kslide_print_loop
    SER ' '
%endif

    ; Trampoline contract (see trampoline: below).
    mov rsi, [v_payload_src]
    mov rdi, KERN_DEST
    add rdi, [v_kslide]
    mov rcx, [v_payload_size]
    mov r8,  [v_fixup_src]
    mov r9,  [v_fixup_count]
    mov r10, [v_kslide]
    mov r11, [v_entry_off]
    SER 'J'             ; J = jumping to trampoline
    mov rax, 0x8000
    jmp rax

.kaslr_bad_magic:
    SDBG 'KASLR-MAGIC'
    jmp .halt

; --- Failure handlers ---
.fail_kernel:
    SDBG 'KERN-FAIL'
    jmp .halt
.fail_exit:
    SDBG 'EXIT-FAIL'
.halt:
    cli
    hlt
    jmp .halt
