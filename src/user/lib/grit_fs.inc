%ifndef GRIT_FS_INC
%define GRIT_FS_INC

; ============================================================================
; GritOS v3.0 - Usermode Filesystem Kit
; Stable helpers for FAT16-backed user apps. The kernel keeps directory-entry
; handles opaque; apps may inspect the copied 32-byte entry returned by
; SYS_FS_ENTRY but must mutate files through these syscalls.
; ============================================================================

NFS_NAME_LEN      equ 11
NFS_ENTRY_SIZE    equ 32
NFS_ATTR_OFF      equ 11
NFS_CLUSTER_OFF   equ 26
NFS_SIZE_OFF      equ 28
NFS_ATTR_DIR      equ 0x10
NFS_ATTR_ARCHIVE  equ 0x20

; NFS_NAME83 dst, src
; Converts a NUL-terminated "NAME.EXT" string into an uppercase FAT 8.3
; space-padded name. dst must point to 11 writable bytes.
%macro NFS_NAME83 2
    push rdi
    push rsi
    mov rdi, %1
    mov rsi, %2
    call nfs_name83
    pop rsi
    pop rdi
%endmacro

; RDI=destination 11-byte buffer, RSI=NUL-terminated source string.
; Returns RAX=0. Invalid FAT characters are copied as-is today; callers that
; need stricter policy should validate their UI input before calling.
nfs_name83:
    push rax
    push rcx
    push rdx
    push rdi
    push rsi

    mov rdx, rdi
    mov ecx, NFS_NAME_LEN
    mov al, ' '
.fill:
    mov [rdx + rcx - 1], al
    loop .fill

    xor ecx, ecx
.name_loop:
    mov al, [rsi]
    test al, al
    jz .done
    cmp al, '.'
    je .ext_start
    cmp ecx, 8
    jae .skip_name_char
    call nfs_toupper_al
    mov [rdx + rcx], al
    inc ecx
.skip_name_char:
    inc rsi
    jmp .name_loop

.ext_start:
    inc rsi
    xor ecx, ecx
.ext_loop:
    mov al, [rsi]
    test al, al
    jz .done
    cmp ecx, 3
    jae .done
    call nfs_toupper_al
    mov [rdx + 8 + rcx], al
    inc ecx
    inc rsi
    jmp .ext_loop

.done:
    xor eax, eax
    pop rsi
    pop rdi
    pop rdx
    pop rcx
    pop rax
    ret

nfs_toupper_al:
    cmp al, 'a'
    jb .ret
    cmp al, 'z'
    ja .ret
    sub al, 32
.ret:
    ret

%endif
