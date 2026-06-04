; Pad text section to full raw size
times (HDR_SZ + TEXT_RAW - ($ - $$)) db 0

; ============================================================================
; .reloc section (minimal - one page entry, zero fixups)
; ============================================================================
    dd 0x1000, 12
    dw 0, 0

times (HDR_SZ + TEXT_RAW + RELOC_FSZ - ($ - $$)) db 0
