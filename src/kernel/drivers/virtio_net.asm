; ============================================================================
; Grit VirtIO-net driver - VirtIO PCI modern + transitional, split virtqueues
; ----------------------------------------------------------------------------
; Supports both the VirtIO 1.x PCI capability transport and the legacy I/O BAR:
;   -device virtio-net-pci,disable-modern=off,disable-legacy=on
;   -device virtio-net-pci,disable-modern=on,disable-legacy=off
;
; The driver is hardware-only at its public boundary: MAC, Ethernet TX, and RX
; pumping. Protocol handling remains behind net_driver.inc. Interrupts and
; optional offloads are not negotiated; bounded polling keeps the first version
; small and makes malformed descriptor lengths fail closed.
; ============================================================================
bits 64

%include "constants.inc"
%include "net_driver.inc"

extern pci_read_conf_dword
extern pci_write_conf_dword
extern rtl8139_handle_frame
extern tick_count
extern debug_print

section .text

VIRTIO_PCI_VENDOR             equ 0x1AF4
VIRTIO_PCI_NET_TRANSITIONAL   equ 0x1000
VIRTIO_PCI_NET_MODERN         equ 0x1041

PCI_STATUS_CAP_LIST           equ (1 << 20)
PCI_CAP_ID_VNDR               equ 0x09
VIRTIO_PCI_CAP_COMMON_CFG     equ 1
VIRTIO_PCI_CAP_NOTIFY_CFG     equ 2
VIRTIO_PCI_CAP_DEVICE_CFG     equ 4

VIRTIO_COMMON_DFSELECT        equ 0
VIRTIO_COMMON_DFEATURE        equ 4
VIRTIO_COMMON_GFSELECT        equ 8
VIRTIO_COMMON_GFEATURE        equ 12
VIRTIO_COMMON_STATUS          equ 20
VIRTIO_COMMON_CFGGEN          equ 21
VIRTIO_COMMON_QSELECT         equ 22
VIRTIO_COMMON_QSIZE           equ 24
VIRTIO_COMMON_QENABLE         equ 28
VIRTIO_COMMON_QNOFF           equ 30
VIRTIO_COMMON_QDESC           equ 32
VIRTIO_COMMON_QDRIVER         equ 40
VIRTIO_COMMON_QDEVICE         equ 48

VIRTIO_PCI_HOST_FEATURES      equ 0x00
VIRTIO_PCI_GUEST_FEATURES     equ 0x04
VIRTIO_PCI_QUEUE_PFN          equ 0x08
VIRTIO_PCI_QUEUE_NUM          equ 0x0C
VIRTIO_PCI_QUEUE_SEL          equ 0x0E
VIRTIO_PCI_QUEUE_NOTIFY       equ 0x10
VIRTIO_PCI_STATUS             equ 0x12
VIRTIO_PCI_ISR                equ 0x13
VIRTIO_PCI_CONFIG             equ 0x14

VIRTIO_STATUS_ACKNOWLEDGE     equ 1
VIRTIO_STATUS_DRIVER          equ 2
VIRTIO_STATUS_DRIVER_OK       equ 4
VIRTIO_STATUS_FEATURES_OK     equ 8
VIRTIO_STATUS_FAILED          equ 0x80

VIRTIO_NET_F_MAC              equ 5

VRING_DESC_F_WRITE            equ 2
VIRTIO_NET_RX_QUEUE           equ 0
VIRTIO_NET_TX_QUEUE           equ 1
VIRTIO_NET_MAX_QUEUE          equ 256

; ---------------------------------------------------------------------------
; virtio_net_init - prefer a modern device, then fall back to transitional.
; Returns EAX=1 active, 0 unavailable/invalid.
; ---------------------------------------------------------------------------
global virtio_net_init
virtio_net_init:
    push rbx
    push rcx
    push rdx
    push rsi
    push rdi
    push r8
    push r9
    push r10
    push r11
    push r12
    push r13
    push r14

    cmp byte [rel virtio_net_active], 1
    je .already
    lea rsi, [rel virtio_ser_init]
    call virtio_ser_puts
    call virtio_net_find_modern
    test eax, eax
    jz .try_legacy
    mov byte [rel virtio_net_transport], 2
    mov word [rel virtio_net_hdr_size], 12
    call virtio_net_init_modern
    test eax, eax
    jz .fail_status
    lea rsi, [rel virtio_ser_modern]
    call virtio_ser_puts
    jmp .common_ready
.try_legacy:
    call virtio_net_find_legacy
    test eax, eax
    jz .fail_no_status
    mov byte [rel virtio_net_transport], 1
    mov word [rel virtio_net_hdr_size], VIRTIO_NET_HDR_SIZE

    ; Reset, then claim the device as a legacy driver.
    mov dx, [rel virtio_net_io_base]
    add dx, VIRTIO_PCI_STATUS
    xor eax, eax
    out dx, al
    mov al, VIRTIO_STATUS_ACKNOWLEDGE | VIRTIO_STATUS_DRIVER
    out dx, al

    ; Negotiate only VIRTIO_NET_F_MAC. Avoid checksum/GSO/mergeable-buffer and
    ; event-index features so every packet has one fixed 10-byte legacy header.
    mov dx, [rel virtio_net_io_base]
    add dx, VIRTIO_PCI_HOST_FEATURES
    in eax, dx
    test eax, (1 << VIRTIO_NET_F_MAC)
    jz .fail_status
    mov dx, [rel virtio_net_io_base]
    add dx, VIRTIO_PCI_GUEST_FEATURES
    mov eax, (1 << VIRTIO_NET_F_MAC)
    out dx, eax

    ; Device configuration starts at +0x14 while MSI-X is disabled. The MAC
    ; feature guarantees six readable bytes here.
    mov dx, [rel virtio_net_io_base]
    add dx, VIRTIO_PCI_CONFIG
    lea rdi, [rel virtio_net_mac]
    mov ecx, 6
.mac:
    in al, dx
    mov [rdi], al
    inc dx
    inc rdi
    loop .mac

    mov esi, VIRTIO_NET_RX_QUEUE
    mov edi, VIRTIO_NET_RX_VQ_ADDR
    call virtio_net_setup_queue_legacy
    test eax, eax
    jz .fail_status
    mov esi, VIRTIO_NET_TX_QUEUE
    mov edi, VIRTIO_NET_TX_VQ_ADDR
    call virtio_net_setup_queue_legacy
    test eax, eax
    jz .fail_status

    lea rsi, [rel virtio_ser_legacy]
    call virtio_ser_puts

.common_ready:
    call virtio_net_seed_rx
    test eax, eax
    jz .fail_status

    cmp byte [rel virtio_net_transport], 2
    je .modern_driver_ok
    mov dx, [rel virtio_net_io_base]
    add dx, VIRTIO_PCI_STATUS
    mov al, VIRTIO_STATUS_ACKNOWLEDGE | VIRTIO_STATUS_DRIVER | VIRTIO_STATUS_DRIVER_OK
    out dx, al
    jmp .mark_active
.modern_driver_ok:
    mov rbx, [rel virtio_net_common_cfg]
    mov byte [rbx + VIRTIO_COMMON_STATUS], VIRTIO_STATUS_ACKNOWLEDGE | VIRTIO_STATUS_DRIVER | VIRTIO_STATUS_FEATURES_OK | VIRTIO_STATUS_DRIVER_OK
    mov eax, VIRTIO_NET_RX_QUEUE
    call virtio_net_notify
.mark_active:
    mov byte [rel virtio_net_active], 1
    lea rsi, [rel virtio_ser_ready]
    call virtio_ser_puts
    mov eax, 1
    jmp .done

.already:
    mov eax, 1
    jmp .done
.fail_status:
    cmp byte [rel virtio_net_transport], 2
    je .fail_modern
    mov dx, [rel virtio_net_io_base]
    add dx, VIRTIO_PCI_STATUS
    mov al, VIRTIO_STATUS_ACKNOWLEDGE | VIRTIO_STATUS_DRIVER | VIRTIO_STATUS_FAILED
    out dx, al
    jmp .fail_no_status
.fail_modern:
    mov rbx, [rel virtio_net_common_cfg]
    test rbx, rbx
    jz .fail_no_status
    mov byte [rbx + VIRTIO_COMMON_STATUS], VIRTIO_STATUS_ACKNOWLEDGE | VIRTIO_STATUS_DRIVER | VIRTIO_STATUS_FAILED
.fail_no_status:
    mov byte [rel virtio_net_active], 0
    mov byte [rel virtio_net_transport], 0
    lea rsi, [rel virtio_ser_fail]
    call virtio_ser_puts
    xor eax, eax
.done:
    pop r14
    pop r13
    pop r12
    pop r11
    pop r10
    pop r9
    pop r8
    pop rdi
    pop rsi
    pop rdx
    pop rcx
    pop rbx
    ret

; Locate a VirtIO 1.x net device and resolve its vendor capabilities into
; identity-mapped MMIO addresses. Capability traversal and BAR indexes are
; bounded so malformed PCI configuration cannot send the kernel wandering.
virtio_net_find_modern:
    push rbx
    push rcx
    push rdx
    push rsi
    push rdi
    push r8
    push r9
    push r10
    push r11
    push r12
    push r13
    push r14
    mov qword [rel virtio_net_common_cfg], 0
    mov qword [rel virtio_net_notify_base], 0
    mov qword [rel virtio_net_device_cfg], 0
    xor r12d, r12d
.bus:
    cmp r12d, 256
    jae .not_found
    xor r13d, r13d
.dev:
    cmp r13d, 32
    jae .next_bus
    xor r14d, r14d
.fn:
    cmp r14d, 8
    jae .next_dev
    mov eax, r12d
    shl eax, 16
    mov ebx, r13d
    shl ebx, 11
    or eax, ebx
    mov ebx, r14d
    shl ebx, 8
    or eax, ebx
    mov [rel virtio_net_pci_addr], eax
    call pci_read_conf_dword
    cmp ax, VIRTIO_PCI_VENDOR
    jne .next_fn
    shr eax, 16
    cmp ax, VIRTIO_PCI_NET_MODERN
    jne .next_fn

    mov eax, [rel virtio_net_pci_addr]
    or eax, 0x04
    call pci_read_conf_dword
    test eax, PCI_STATUS_CAP_LIST
    jz .next_fn
    or eax, 0x0006                  ; memory space + bus master
    mov ecx, eax
    mov eax, [rel virtio_net_pci_addr]
    or eax, 0x04
    call pci_write_conf_dword

    mov eax, [rel virtio_net_pci_addr]
    or eax, 0x34
    call pci_read_conf_dword
    movzx esi, al
    mov edi, 48                     ; hard cap on linked-list traversal
.cap_loop:
    test esi, esi
    jz .caps_done
    test edi, edi
    jz .next_fn
    dec edi
    cmp esi, 0x40
    jb .next_fn
    cmp esi, 0xFC
    ja .next_fn
    test esi, 3
    jnz .next_fn
    mov eax, [rel virtio_net_pci_addr]
    or eax, esi
    call pci_read_conf_dword
    mov ecx, eax
    shr ecx, 8
    and ecx, 0xFF
    mov r11d, ecx                    ; next capability
    cmp al, PCI_CAP_ID_VNDR
    jne .cap_next
    mov ecx, eax
    shr ecx, 16
    cmp cl, 16                      ; base virtio_pci_cap size
    jb .next_fn
    mov r8d, eax
    shr r8d, 24                     ; cfg_type
    cmp r8d, VIRTIO_PCI_CAP_NOTIFY_CFG
    jne .cap_type_checked
    cmp cl, 20                      ; notify cap includes multiplier at +16
    jb .next_fn
.cap_type_checked:
    cmp r8d, VIRTIO_PCI_CAP_COMMON_CFG
    je .resolve_cap
    cmp r8d, VIRTIO_PCI_CAP_NOTIFY_CFG
    je .resolve_cap
    cmp r8d, VIRTIO_PCI_CAP_DEVICE_CFG
    jne .cap_next
.resolve_cap:
    mov eax, [rel virtio_net_pci_addr]
    lea eax, [eax + esi + 4]
    call pci_read_conf_dword
    movzx ebx, al                   ; BAR index
    cmp ebx, 5
    ja .next_fn
    mov eax, [rel virtio_net_pci_addr]
    lea eax, [eax + esi + 8]
    call pci_read_conf_dword
    mov r9d, eax                    ; offset within BAR
    mov eax, [rel virtio_net_pci_addr]
    lea eax, [eax + esi + 12]
    call pci_read_conf_dword
    mov r10d, eax                   ; capability window length
    call virtio_net_get_bar
    test rax, rax
    jz .next_fn
    add rax, r9
    jc .next_fn
    cmp r8d, VIRTIO_PCI_CAP_COMMON_CFG
    je .common_cap
    cmp r8d, VIRTIO_PCI_CAP_NOTIFY_CFG
    je .notify_cap
    cmp r8d, VIRTIO_PCI_CAP_DEVICE_CFG
    je .device_cap
    jmp .cap_next
.common_cap:
    cmp r10d, 56
    jb .next_fn
    mov [rel virtio_net_common_cfg], rax
    jmp .cap_next
.notify_cap:
    cmp r10d, 2
    jb .next_fn
    mov [rel virtio_net_notify_base], rax
    mov [rel virtio_net_notify_len], r10d
    mov eax, [rel virtio_net_pci_addr]
    lea eax, [eax + esi + 16]
    call pci_read_conf_dword
    test eax, eax
    jz .next_fn
    mov [rel virtio_net_notify_mult], eax
    jmp .cap_next
.device_cap:
    cmp r10d, 6
    jb .next_fn
    mov [rel virtio_net_device_cfg], rax
.cap_next:
    mov esi, r11d
    jmp .cap_loop
.caps_done:
    cmp qword [rel virtio_net_common_cfg], 0
    je .next_fn
    cmp qword [rel virtio_net_notify_base], 0
    je .next_fn
    cmp qword [rel virtio_net_device_cfg], 0
    je .next_fn
    mov eax, 1
    jmp .done
.next_fn:
    inc r14d
    jmp .fn
.next_dev:
    inc r13d
    jmp .dev
.next_bus:
    inc r12d
    jmp .bus
.not_found:
    xor eax, eax
.done:
    pop r14
    pop r13
    pop r12
    pop r11
    pop r10
    pop r9
    pop r8
    pop rdi
    pop rsi
    pop rdx
    pop rcx
    pop rbx
    ret

; EBX=BAR index, returns RAX=memory BAR base or zero. QEMU's PCI hole is
; identity mapped; 64-bit BARs are accepted when their resulting address is.
virtio_net_get_bar:
    push rbx
    push rcx
    push rdx
    mov edx, ebx
    shl edx, 2
    add edx, 0x10
    mov eax, [rel virtio_net_pci_addr]
    or eax, edx
    call pci_read_conf_dword
    test eax, 1
    jnz .bad
    mov ecx, eax
    and ecx, 0xFFFFFFF0
    and eax, 6
    cmp eax, 4
    jne .low
    cmp ebx, 5
    jae .bad
    add edx, 4
    mov eax, [rel virtio_net_pci_addr]
    or eax, edx
    call pci_read_conf_dword
    shl rax, 32
    or rax, rcx
    jmp .check
.low:
    mov eax, ecx
.check:
    test rax, rax
    jz .bad
    jmp .out
.bad:
    xor eax, eax
.out:
    pop rdx
    pop rcx
    pop rbx
    ret

; Negotiate the mandatory VERSION_1 feature plus MAC, read stable device
; configuration, then publish the two split virtqueues through common_cfg.
virtio_net_init_modern:
    push rbx
    push rcx
    push rdi
    push rsi
    push r8
    mov rbx, [rel virtio_net_common_cfg]
    mov byte [rbx + VIRTIO_COMMON_STATUS], 0
    mov ecx, 100000
.reset_wait:
    cmp byte [rbx + VIRTIO_COMMON_STATUS], 0
    je .reset_done
    pause
    loop .reset_wait
    jmp .bad
.reset_done:
    mov byte [rbx + VIRTIO_COMMON_STATUS], VIRTIO_STATUS_ACKNOWLEDGE | VIRTIO_STATUS_DRIVER
    mov dword [rbx + VIRTIO_COMMON_DFSELECT], 0
    mov eax, [rbx + VIRTIO_COMMON_DFEATURE]
    test eax, (1 << VIRTIO_NET_F_MAC)
    jz .bad
    mov dword [rbx + VIRTIO_COMMON_DFSELECT], 1
    mov eax, [rbx + VIRTIO_COMMON_DFEATURE]
    test eax, 1                     ; VIRTIO_F_VERSION_1 (feature bit 32)
    jz .bad
    mov dword [rbx + VIRTIO_COMMON_GFSELECT], 0
    mov dword [rbx + VIRTIO_COMMON_GFEATURE], (1 << VIRTIO_NET_F_MAC)
    mov dword [rbx + VIRTIO_COMMON_GFSELECT], 1
    mov dword [rbx + VIRTIO_COMMON_GFEATURE], 1
    mov byte [rbx + VIRTIO_COMMON_STATUS], VIRTIO_STATUS_ACKNOWLEDGE | VIRTIO_STATUS_DRIVER | VIRTIO_STATUS_FEATURES_OK
    test byte [rbx + VIRTIO_COMMON_STATUS], VIRTIO_STATUS_FEATURES_OK
    jz .bad

    mov rsi, [rel virtio_net_device_cfg]
    mov r8d, 8
.mac_retry:
    mov al, [rbx + VIRTIO_COMMON_CFGGEN]
    mov dl, al
    lea rdi, [rel virtio_net_mac]
    mov ecx, 6
.mac:
    mov al, [rsi]
    mov [rdi], al
    inc rsi
    inc rdi
    loop .mac
    mov rsi, [rel virtio_net_device_cfg]
    cmp dl, [rbx + VIRTIO_COMMON_CFGGEN]
    je .mac_stable
    dec r8d
    jnz .mac_retry
    jmp .bad
.mac_stable:

    mov esi, VIRTIO_NET_RX_QUEUE
    mov edi, VIRTIO_NET_RX_VQ_ADDR
    call virtio_net_setup_queue_modern
    test eax, eax
    jz .bad
    mov esi, VIRTIO_NET_TX_QUEUE
    mov edi, VIRTIO_NET_TX_VQ_ADDR
    call virtio_net_setup_queue_modern
    test eax, eax
    jz .bad
    mov eax, 1
    jmp .out
.bad:
    xor eax, eax
.out:
    pop r8
    pop rsi
    pop rdi
    pop rcx
    pop rbx
    ret

; Locate PCI 1af4:1000, enable I/O + bus mastering, and capture BAR0.
virtio_net_find_legacy:
    push rbx
    push rcx
    push rdx
    push r12
    push r13
    push r14
    xor r12d, r12d
.bus:
    cmp r12d, 256
    jae .not_found
    xor r13d, r13d
.dev:
    cmp r13d, 32
    jae .next_bus
    xor r14d, r14d
.fn:
    cmp r14d, 8
    jae .next_dev
    mov eax, r12d
    shl eax, 16
    mov ebx, r13d
    shl ebx, 11
    or eax, ebx
    mov ebx, r14d
    shl ebx, 8
    or eax, ebx
    mov [rel virtio_net_pci_addr], eax
    call pci_read_conf_dword
    cmp ax, VIRTIO_PCI_VENDOR
    jne .next_fn
    shr eax, 16
    cmp ax, VIRTIO_PCI_NET_TRANSITIONAL
    jne .next_fn

    mov eax, [rel virtio_net_pci_addr]
    or eax, 0x04
    call pci_read_conf_dword
    or eax, 0x0005                  ; I/O space + bus master
    mov ecx, eax
    mov eax, [rel virtio_net_pci_addr]
    or eax, 0x04
    call pci_write_conf_dword

    mov eax, [rel virtio_net_pci_addr]
    or eax, 0x10
    call pci_read_conf_dword
    test eax, 1                    ; transitional BAR0 must be I/O space
    jz .not_found
    and eax, 0xFFFFFFFC
    test eax, eax
    jz .not_found
    mov [rel virtio_net_io_base], ax
    mov eax, 1
    jmp .find_done
.next_fn:
    inc r14d
    jmp .fn
.next_dev:
    inc r13d
    jmp .dev
.next_bus:
    inc r12d
    jmp .bus
.not_found:
    xor eax, eax
.find_done:
    pop r14
    pop r13
    pop r12
    pop rdx
    pop rcx
    pop rbx
    ret

; ESI=queue index, EDI=64-KiB-aligned physical queue region. Returns EAX=1/0.
; Derived split-ring layout:
;   desc  = base
;   avail = base + 16*qsz
;   used  = align_up(avail + 6 + 2*qsz, 4096)
virtio_net_setup_queue_legacy:
    push rbx
    push rcx
    push rdx
    push rdi
    push r8
    push r9
    mov r8d, edi

    ; Clear the entire dedicated queue slot before exposing its PFN.
    mov ecx, VIRTIO_NET_VQ_REGION_SIZE / 8
    xor eax, eax
    cld
    rep stosq

    mov dx, [rel virtio_net_io_base]
    add dx, VIRTIO_PCI_QUEUE_SEL
    mov eax, esi
    out dx, ax
    mov dx, [rel virtio_net_io_base]
    add dx, VIRTIO_PCI_QUEUE_NUM
    in ax, dx
    movzx ebx, ax
    test ebx, ebx
    jz .bad
    cmp ebx, VIRTIO_NET_MAX_QUEUE
    ja .bad
    mov eax, ebx
    dec eax
    test ebx, eax                    ; split-ring modulo assumes power of two
    jnz .bad

    mov dx, [rel virtio_net_io_base]
    add dx, VIRTIO_PCI_QUEUE_PFN
    in eax, dx
    test eax, eax
    jnz .bad

    mov r9d, ebx
    shl r9d, 4
    add r9d, r8d                     ; avail
    mov eax, ebx
    shl eax, 1
    lea eax, [r9d + eax + 6]
    add eax, 4095
    and eax, 0xFFFFF000              ; used
    mov ecx, eax
    sub ecx, r8d
    add ecx, 6 + (8 * VIRTIO_NET_MAX_QUEUE)
    cmp ecx, VIRTIO_NET_VQ_REGION_SIZE
    ja .bad

    cmp esi, VIRTIO_NET_RX_QUEUE
    jne .store_tx
    mov [rel virtio_rx_queue_size], bx
    mov [rel virtio_rx_avail], r9
    mov [rel virtio_rx_used], rax
    jmp .publish
.store_tx:
    mov [rel virtio_tx_queue_size], bx
    mov [rel virtio_tx_avail], r9
    mov [rel virtio_tx_used], rax
.publish:
    mov eax, r8d
    shr eax, 12
    mov dx, [rel virtio_net_io_base]
    add dx, VIRTIO_PCI_QUEUE_PFN
    out dx, eax
    mov eax, 1
    jmp .queue_done
.bad:
    xor eax, eax
.queue_done:
    pop r9
    pop r8
    pop rdi
    pop rdx
    pop rcx
    pop rbx
    ret

; ESI=queue index, EDI=64-KiB queue region. The modern transport publishes
; descriptor/driver/device addresses independently and enables the queue.
virtio_net_setup_queue_modern:
    push rbx
    push rcx
    push rdx
    push rdi
    push r8
    push r9
    push r10
    mov r8d, edi
    mov ecx, VIRTIO_NET_VQ_REGION_SIZE / 8
    xor eax, eax
    cld
    rep stosq

    mov rbx, [rel virtio_net_common_cfg]
    mov [rbx + VIRTIO_COMMON_QSELECT], si
    cmp word [rbx + VIRTIO_COMMON_QENABLE], 0
    jne .bad
    movzx edx, word [rbx + VIRTIO_COMMON_QSIZE]
    test edx, edx
    jz .bad
    cmp edx, VIRTIO_NET_MAX_QUEUE
    ja .bad
    mov eax, edx
    dec eax
    test edx, eax
    jnz .bad
    mov [rbx + VIRTIO_COMMON_QSIZE], dx
    cmp esi, VIRTIO_NET_RX_QUEUE
    jne .save_tx_size
    mov [rel virtio_rx_queue_size], dx
    jmp .size_saved
.save_tx_size:
    mov [rel virtio_tx_queue_size], dx
.size_saved:

    mov r9d, edx
    shl r9d, 4
    add r9d, r8d                    ; driver (available) ring
    mov eax, edx
    shl eax, 1
    lea r10d, [r9d + eax + 6]
    add r10d, 4095
    and r10d, 0xFFFFF000            ; device (used) ring
    mov eax, r10d
    sub eax, r8d
    add eax, 6 + (8 * VIRTIO_NET_MAX_QUEUE)
    cmp eax, VIRTIO_NET_VQ_REGION_SIZE
    ja .bad

    mov [rbx + VIRTIO_COMMON_QDESC], r8
    mov [rbx + VIRTIO_COMMON_QDRIVER], r9
    mov [rbx + VIRTIO_COMMON_QDEVICE], r10
    movzx eax, word [rbx + VIRTIO_COMMON_QNOFF]
    mul dword [rel virtio_net_notify_mult]
    test edx, edx
    jnz .bad
    mov ecx, eax
    add ecx, 2
    jc .bad
    cmp ecx, [rel virtio_net_notify_len]
    ja .bad
    add rax, [rel virtio_net_notify_base]
    jc .bad

    cmp esi, VIRTIO_NET_RX_QUEUE
    jne .store_tx
    mov [rel virtio_rx_avail], r9
    mov [rel virtio_rx_used], r10
    mov [rel virtio_rx_notify], rax
    jmp .enable
.store_tx:
    mov [rel virtio_tx_avail], r9
    mov [rel virtio_tx_used], r10
    mov [rel virtio_tx_notify], rax
.enable:
    mov word [rbx + VIRTIO_COMMON_QENABLE], 1
    mov eax, 1
    jmp .done
.bad:
    xor eax, eax
.done:
    pop r10
    pop r9
    pop r8
    pop rdi
    pop rdx
    pop rcx
    pop rbx
    ret

; EAX=queue index. Notify through MMIO for modern or the I/O register for
; transitional. Notification data was not negotiated, so the value is qidx.
virtio_net_notify:
    cmp byte [rel virtio_net_transport], 2
    je .modern
    mov dx, [rel virtio_net_io_base]
    add dx, VIRTIO_PCI_QUEUE_NOTIFY
    out dx, ax
    ret
.modern:
    cmp eax, VIRTIO_NET_RX_QUEUE
    jne .modern_tx
    mov rdx, [rel virtio_rx_notify]
    mov word [rdx], ax
    ret
.modern_tx:
    mov rdx, [rel virtio_tx_notify]
    mov word [rdx], ax
    ret

; Populate eight writable RX descriptors and publish them in queue 0.
virtio_net_seed_rx:
    push rbx
    push rcx
    push rdx
    push rdi
    movzx eax, word [rel virtio_rx_queue_size]
    cmp eax, VIRTIO_NET_RX_SLOTS
    jb .seed_fail
    xor ebx, ebx
.seed_loop:
    cmp ebx, VIRTIO_NET_RX_SLOTS
    jae .seed_publish
    mov eax, ebx
    shl eax, 4
    lea rdi, [abs VIRTIO_NET_RX_VQ_ADDR + rax]
    mov eax, ebx
    shl eax, 11
    add eax, VIRTIO_NET_RX_BUF_ADDR
    mov [rdi + 0], rax
    mov dword [rdi + 8], VIRTIO_NET_RX_BUF_SIZE
    mov word [rdi + 12], VRING_DESC_F_WRITE
    mov word [rdi + 14], 0
    mov rdi, [rel virtio_rx_avail]
    mov [rdi + 4 + rbx*2], bx
    inc ebx
    jmp .seed_loop
.seed_publish:
    mov rdi, [rel virtio_rx_avail]
    mfence
    mov word [rdi + 2], VIRTIO_NET_RX_SLOTS
    mov word [rel virtio_rx_last_used], 0
    mov eax, 1
    jmp .seed_done
.seed_fail:
    xor eax, eax
.seed_done:
    pop rdi
    pop rdx
    pop rcx
    pop rbx
    ret

; RDI=complete Ethernet frame, ECX=length. Synchronous one-descriptor TX.
global virtio_net_tx_frame
virtio_net_tx_frame:
    push rbx
    push rcx
    push rdx
    push rsi
    push rdi
    push r8
    push r9
    cmp byte [rel virtio_net_active], 1
    jne .tx_fail
    cmp ecx, 14
    jb .tx_fail
    cmp ecx, VIRTIO_NET_MAX_FRAME
    ja .tx_fail
    mov r8d, ecx
    mov rsi, rdi
    mov rdi, VIRTIO_NET_TX_BUF_ADDR
    xor eax, eax
    movzx ecx, word [rel virtio_net_hdr_size]
    cld
    rep stosb
    mov ecx, r8d
    rep movsb

    mov qword [abs VIRTIO_NET_TX_VQ_ADDR + 0], VIRTIO_NET_TX_BUF_ADDR
    movzx eax, word [rel virtio_net_hdr_size]
    add eax, r8d
    mov [abs VIRTIO_NET_TX_VQ_ADDR + 8], eax
    mov word [abs VIRTIO_NET_TX_VQ_ADDR + 12], 0
    mov word [abs VIRTIO_NET_TX_VQ_ADDR + 14], 0

    mov rdi, [rel virtio_tx_avail]
    movzx ebx, word [rdi + 2]
    movzx edx, word [rel virtio_tx_queue_size]
    dec edx
    mov eax, ebx
    and eax, edx
    mov word [rdi + 4 + rax*2], 0
    mfence
    inc bx
    mov [rdi + 2], bx
    mfence
    mov eax, VIRTIO_NET_TX_QUEUE
    call virtio_net_notify

    ; The single TX buffer is not reused until its used entry arrives.
    mov r9, [rel tick_count]
    add r9, 100
.tx_wait:
    mov rdi, [rel virtio_tx_used]
    movzx eax, word [rdi + 2]
    cmp ax, [rel virtio_tx_last_used]
    jne .tx_done
    mov rax, [rel tick_count]
    cmp rax, r9
    jae .tx_fail
    pause
    jmp .tx_wait
.tx_done:
    mov [rel virtio_tx_last_used], ax
    mov eax, 1
    jmp .tx_out
.tx_fail:
    xor eax, eax
.tx_out:
    pop r9
    pop r8
    pop rdi
    pop rsi
    pop rdx
    pop rcx
    pop rbx
    ret

; Poll queue 0, validate each device-written used element, deliver the Ethernet
; frame, then recycle the same bounded descriptor. At most RX_SLOTS entries are
; consumed per call so a hostile device cannot monopolize the kernel loop.
global virtio_net_poll_rx
virtio_net_poll_rx:
    push rbx
    push rcx
    push rdx
    push rsi
    push rdi
    push r8
    push r9
    push r10
    push r11
    cmp byte [rel virtio_net_active], 1
    jne .rx_none
    xor r11d, r11d                   ; processed count
.rx_loop:
    cmp r11d, VIRTIO_NET_RX_SLOTS
    jae .rx_notify
    mov rdi, [rel virtio_rx_used]
    movzx eax, word [rdi + 2]
    movzx ebx, word [rel virtio_rx_last_used]
    cmp bx, ax
    je .rx_notify
    mfence
    movzx edx, word [rel virtio_rx_queue_size]
    dec edx
    mov ecx, ebx
    and ecx, edx
    lea rsi, [rdi + 4 + rcx*8]
    mov r8d, [rsi + 0]               ; descriptor id (device supplied)
    mov r9d, [rsi + 4]               ; bytes written (device supplied)
    inc bx
    mov [rel virtio_rx_last_used], bx
    cmp r8d, VIRTIO_NET_RX_SLOTS
    jae .rx_recycle_skip
    movzx eax, word [rel virtio_net_hdr_size]
    add eax, 14
    cmp r9d, eax
    jb .rx_recycle
    cmp r9d, VIRTIO_NET_RX_BUF_SIZE
    ja .rx_recycle
    mov eax, r8d
    shl eax, 11
    add rax, VIRTIO_NET_RX_BUF_ADDR
    movzx edx, word [rel virtio_net_hdr_size]
    add rax, rdx
    mov rdi, rax
    mov ecx, r9d
    movzx edx, word [rel virtio_net_hdr_size]
    sub ecx, edx
    call rtl8139_handle_frame          ; shared Ethernet + DHCP/ICMP demux
.rx_recycle:
    mov rdi, [rel virtio_rx_avail]
    movzx eax, word [rdi + 2]
    movzx edx, word [rel virtio_rx_queue_size]
    dec edx
    and edx, eax
    mov [rdi + 4 + rdx*2], r8w
    mfence
    inc ax
    mov [rdi + 2], ax
.rx_recycle_skip:
    inc r11d
    jmp .rx_loop
.rx_notify:
    test r11d, r11d
    jz .rx_none
    mfence
    mov eax, VIRTIO_NET_RX_QUEUE
    call virtio_net_notify
    mov eax, 1
    jmp .rx_out
.rx_none:
    xor eax, eax
.rx_out:
    pop r11
    pop r10
    pop r9
    pop r8
    pop rdi
    pop rsi
    pop rdx
    pop rcx
    pop rbx
    ret

virtio_ser_putc:
%ifdef RELEASE_BUILD
    ret
%endif
    push rax
    push rdx
    mov dx, 0x3F8
    out dx, al
    pop rdx
    pop rax
    ret

virtio_ser_puts:
    push rax
    push rsi
.puts_loop:
    mov al, [rsi]
    test al, al
    jz .puts_done
    call virtio_ser_putc
    inc rsi
    jmp .puts_loop
.puts_done:
    pop rsi
    pop rax
    ret

section .data
virtio_ser_init  db "[VNET INIT]", 10, 0
virtio_ser_ready db "[VNET READY]", 10, 0
virtio_ser_fail  db "[VNET UNAVAILABLE]", 10, 0
virtio_ser_modern db "[VNET MODERN]", 10, 0
virtio_ser_legacy db "[VNET LEGACY]", 10, 0

section .bss
global virtio_net_active
global virtio_net_mac
virtio_net_active:       resb 1
virtio_net_transport:    resb 1
virtio_net_io_base:      resw 1
virtio_net_pci_addr:     resd 1
virtio_net_mac:          resb 6
align 8
virtio_net_common_cfg:   resq 1
virtio_net_notify_base:  resq 1
virtio_net_device_cfg:   resq 1
virtio_rx_notify:        resq 1
virtio_tx_notify:        resq 1
virtio_net_notify_mult:  resd 1
virtio_net_notify_len:   resd 1
virtio_net_hdr_size:     resw 1
virtio_rx_avail:         resq 1
virtio_rx_used:          resq 1
virtio_tx_avail:         resq 1
virtio_tx_used:          resq 1
virtio_rx_queue_size:    resw 1
virtio_tx_queue_size:    resw 1
virtio_rx_last_used:     resw 1
virtio_tx_last_used:     resw 1
