; ============================================================================
; Owner: src/boot/boot.asm legacy standalone UEFI image
; Section: Legacy UEFI image padding and reloc block
; Included by boot.asm in boot order; keep binary-emitting statements ordered.
; ============================================================================

; PAD
times (HEADER_SIZE + TEXT_RAWSIZE - ($-$$)) db 0

; .reloc
reloc_s:
    dd 0x1000, 12
    dw 0, 0
times (RELOC_FSIZE - ($-reloc_s)) db 0
