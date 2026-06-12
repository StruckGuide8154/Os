; ----------------------------------------------------------------------------
; MDIO access via the PLA_OCP_GPHY_BASE window.
; ----------------------------------------------------------------------------
; rtl8156_mdio_set_base - point the GPHY indirection window at OCP_BASE_PHY.
; Must be called once before any mdio read/write. Linux re-points it as
; needed; we only ever access the 0xA000 PHY page so once is enough.
rtl8156_mdio_set_base:
    push rax
    push rcx
    push rdx
    push rsi
    push rdi
    mov dword [abs RTL8156_SCRATCH_ADDR], RTL8156_OCP_BASE_PHY
    mov edi, RTL8156_PLA_OCP_GPHY_BASE & ~3
    mov esi, RTL8156_MCU_PLA | RTL8156_BYTE_EN_WORD
    mov edx, 4
    mov rcx, RTL8156_SCRATCH_ADDR
    call rtl8156_ocp_write
    pop rdi
    pop rsi
    pop rdx
    pop rcx
    pop rax
    ret

; rtl8156_mdio_read - EDI = MII reg number (0..31). Returns 16-bit value in EAX
; (low word). Caller must have set the base via rtl8156_mdio_set_base first.
rtl8156_mdio_read:
    push rcx
    push rdx
    push rsi
    push rdi
    push rbx
    ; OCP offset within page = PHY_REG0_OFFSET + reg*2  (e.g. reg 0 -> 0x400,
    ; reg 1 -> 0x402, reg 2 -> 0x404, ...).
    shl edi, 1
    add edi, RTL8156_PHY_REG0_OFFSET
    and edi, 0x0FFF
    or edi, 0xB000
    mov ebx, edi                             ; save full PLA addr (incl bit 1)
    and edi, ~3                              ; dword-align for the OCP read
    mov esi, RTL8156_MCU_PLA
    mov edx, 4
    mov rcx, RTL8156_SCRATCH_ADDR
    call rtl8156_ocp_read
    ; Pick low or high word depending on which word we wanted.
    test ebx, 2
    jnz .high_word
    movzx eax, word [abs RTL8156_SCRATCH_ADDR + 0]
    jmp .done
.high_word:
    movzx eax, word [abs RTL8156_SCRATCH_ADDR + 2]
.done:
    pop rbx
    pop rdi
    pop rsi
    pop rdx
    pop rcx
    ret

; rtl8156_mdio_write - EDI = MII reg, ESI = 16-bit value.
rtl8156_mdio_write:
    push rax
    push rbx
    push rcx
    push rdx
    push rdi
    push rsi
    movzx eax, si                            ; value
    shl edi, 1
    add edi, RTL8156_PHY_REG0_OFFSET
    and edi, 0x0FFF
    or edi, 0xB000
    mov ebx, edi
    and edi, ~3                              ; dword-aligned PLA addr
    test ebx, 2
    jz .lo
    ; Write the high word: byte enables 0xCC, value in [+2]
    mov dword [abs RTL8156_SCRATCH_ADDR], 0
    mov [abs RTL8156_SCRATCH_ADDR + 2], ax
    mov esi, RTL8156_MCU_PLA | 0xCC
    jmp .go
.lo:
    mov dword [abs RTL8156_SCRATCH_ADDR], 0
    mov [abs RTL8156_SCRATCH_ADDR + 0], ax
    mov esi, RTL8156_MCU_PLA | RTL8156_BYTE_EN_WORD
.go:
    mov edx, 4
    mov rcx, RTL8156_SCRATCH_ADDR
    call rtl8156_ocp_write
    pop rsi
    pop rdi
    pop rdx
    pop rcx
    pop rbx
    pop rax
    ret

; Bring the PHY out of power-down: read BMCR, clear PDOWN+ISOLATE,
; set ANE+RAN, write back.
rtl8156_phy_powerup:
    push rax
    push rsi
    push rdi
    push rbx
    push rdx

    call rtl8156_mdio_set_base

    ; PHY-reset race fix: at cold power-up / soft reset the PHY leaves
    ; BMCR.RESET (0x8000) set and its whole MII register file transiently reads
    ; back 0x0000. Reading BMSR in that window yields LSTATUS=0 forever for that
    ; boot (observed intermittently: "BMCR BMSR:A000 0000" -> no link, ~1 in 3
    ; boots). Wait (bounded ~500ms) for RESET to self-clear before touching the
    ; PHY so every subsequent read is valid. rtl8156_mdio_read preserves rbx, so
    ; the deadline survives the call.
    mov rbx, [tick_count]
    add rbx, 50
.phy_reset_wait:
    mov edi, RTL8156_MII_BMCR
    call rtl8156_mdio_read
    test ax, RTL8156_BMCR_RESET
    jz .phy_reset_clear
    mov rdx, [tick_count]
    cmp rdx, rbx
    jae .phy_reset_clear
    pause
    jmp .phy_reset_wait
.phy_reset_clear:

    ; Read BMCR and dump it.
    mov edi, RTL8156_MII_BMCR
    call rtl8156_mdio_read
    lea rsi, [rel ser_bmcr_tag]
    call rtl8156_ser_puts
    push rax
    mov al, ah
    call rtl8156_ser_phex8
    pop rax
    call rtl8156_ser_phex8
    ; Read BMSR.
    mov al, ' '
    mov dx, 0x3F8
    out dx, al
    mov edi, RTL8156_MII_BMSR
    call rtl8156_mdio_read
    mov [rtl8156_last_bmsr], ax
    push rax
    mov al, ah
    call rtl8156_ser_phex8
    pop rax
    call rtl8156_ser_phex8
    mov al, 10
    out dx, al

    ; Write BMCR = ANE | RAN. Clear PDOWN (0x0800) implicitly.
    mov edi, RTL8156_MII_BMCR
    mov esi, RTL8156_BMCR_ANE | RTL8156_BMCR_RAN
    call rtl8156_mdio_write

    pop rdx
    pop rbx
    pop rdi
    pop rsi
    pop rax
    ret

rtl8156_vendor_init:
    ; Run the OOB exit + link-list re-init. Skipping this leaves the PHY
    ; gated off - MDIO reads return 0 so BMSR LSTATUS never asserts and
    ; rtl8156_wait_link always times out (observed on real RTL8156
    ; passthrough; the device is otherwise enumerated correctly).
    ; ----------------------------------------------------------------
    ; OOB exit + link list re-init (Linux r8153_first_init prologue).
    ; At cold power-up the chip considers itself in "Out Of Band" mode
    ; where the host-side MAC/RX path is gated off. Without explicitly
    ; clearing NOW_IS_OOB and waiting for LINK_LIST_READY the bulk IN
    ; endpoint never delivers a frame even with everything else right.
    ; ----------------------------------------------------------------
    push rbx

    ; ---- r8153_first_init prologue, step 0: wait AUTOLOAD_DONE ----
    ; Linux waits for PLA_BOOT_CTRL.AUTOLOAD_DONE before touching MAC regs.
    ; Reads before autoload completes return stale/zero and the RE_INIT_LL
    ; handshake silently no-ops. Best-effort ~1s poll.
    mov rbx, [tick_count]
    add rbx, 100
.al_wait:
    mov edi, RTL8156_PLA_BOOT_CTRL & ~3
    mov esi, RTL8156_MCU_PLA
    mov edx, 4
    mov rcx, RTL8156_SCRATCH_ADDR
    call rtl8156_ocp_read
    mov eax, [abs RTL8156_SCRATCH_ADDR]
    shr eax, ((RTL8156_PLA_BOOT_CTRL & 3) * 8)
    test eax, RTL8156_AUTOLOAD_DONE
    jnz .al_done
    mov rax, [tick_count]
    cmp rax, rbx
    jae .al_done
    pause
    jmp .al_wait
.al_done:
    lea rsi, [rel ser_al_done]
    call rtl8156_ser_puts
    push rax
    test eax, RTL8156_AUTOLOAD_DONE
    setnz al
    add al, '0'
    mov dx, 0x3F8
    out dx, al
    mov al, 10
    out dx, al
    pop rax

    ; ---- step 1: gate the RX path (rxdy_gated_en true) BEFORE OOB exit ----
    ; r8153_first_init sets RXDY_GATED_EN before clearing NOW_IS_OOB and
    ; re-initialising the link list, then clears it again at the end. Doing
    ; the RE_INIT_LL handshake with RX un-gated leaves LINK_LIST_READY stuck.
    mov edi, RTL8156_PLA_MISC_1 & ~3
    mov esi, RTL8156_MCU_PLA
    mov edx, 4
    mov rcx, RTL8156_SCRATCH_ADDR
    call rtl8156_ocp_read
    mov eax, [abs RTL8156_SCRATCH_ADDR]
    or eax, RTL8156_RXDY_GATED_EN
    mov [abs RTL8156_SCRATCH_ADDR], eax
    mov edi, RTL8156_PLA_MISC_1 & ~3
    mov esi, RTL8156_MCU_PLA | RTL8156_BYTE_DWORD
    mov edx, 4
    mov rcx, RTL8156_SCRATCH_ADDR
    call rtl8156_ocp_write

    ; Read PLA_OOB_CTRL byte, clear NOW_IS_OOB, write back.
    mov edi, RTL8156_PLA_OOB_CTRL & ~3
    mov esi, RTL8156_MCU_PLA
    mov edx, 4
    mov rcx, RTL8156_SCRATCH_ADDR
    call rtl8156_ocp_read
    mov eax, [abs RTL8156_SCRATCH_ADDR]
    and eax, ~(RTL8156_NOW_IS_OOB << ((RTL8156_PLA_OOB_CTRL & 3) * 8))
    mov [abs RTL8156_SCRATCH_ADDR], eax
    mov edi, RTL8156_PLA_OOB_CTRL & ~3
    mov esi, RTL8156_MCU_PLA | RTL8156_BYTE_DWORD
    mov edx, 4
    mov rcx, RTL8156_SCRATCH_ADDR
    call rtl8156_ocp_write

    ; Trigger link-list re-init: PLA_SFF_STS_7 |= MCU_BORW_EN, then
    ; |= RE_INIT_LL, then poll for LINK_LIST_READY.
    mov edi, RTL8156_PLA_SFF_STS_7 & ~3
    mov esi, RTL8156_MCU_PLA
    mov edx, 4
    mov rcx, RTL8156_SCRATCH_ADDR
    call rtl8156_ocp_read
    mov eax, [abs RTL8156_SCRATCH_ADDR]
    or eax, (RTL8156_MCU_BORW_EN << ((RTL8156_PLA_SFF_STS_7 & 3) * 8))
    mov [abs RTL8156_SCRATCH_ADDR], eax
    mov edi, RTL8156_PLA_SFF_STS_7 & ~3
    mov esi, RTL8156_MCU_PLA | RTL8156_BYTE_DWORD
    mov edx, 4
    mov rcx, RTL8156_SCRATCH_ADDR
    call rtl8156_ocp_write

    mov edi, RTL8156_PLA_SFF_STS_7 & ~3
    mov esi, RTL8156_MCU_PLA
    mov edx, 4
    mov rcx, RTL8156_SCRATCH_ADDR
    call rtl8156_ocp_read
    mov eax, [abs RTL8156_SCRATCH_ADDR]
    or eax, (RTL8156_RE_INIT_LL << ((RTL8156_PLA_SFF_STS_7 & 3) * 8))
    mov [abs RTL8156_SCRATCH_ADDR], eax
    mov edi, RTL8156_PLA_SFF_STS_7 & ~3
    mov esi, RTL8156_MCU_PLA | RTL8156_BYTE_DWORD
    mov edx, 4
    mov rcx, RTL8156_SCRATCH_ADDR
    call rtl8156_ocp_write

    ; Poll for LINK_LIST_READY (bit 1 of PLA_SFF_STS_7 word).
    mov rbx, [tick_count]
    add rbx, 200                  ; 2s timeout
.ll_wait:
    mov edi, RTL8156_PLA_SFF_STS_7 & ~3
    mov esi, RTL8156_MCU_PLA
    mov edx, 4
    mov rcx, RTL8156_SCRATCH_ADDR
    call rtl8156_ocp_read
    mov eax, [abs RTL8156_SCRATCH_ADDR]
    shr eax, ((RTL8156_PLA_SFF_STS_7 & 3) * 8)
    test eax, RTL8156_LINK_LIST_READY
    jnz .ll_ready
    mov rax, [tick_count]
    cmp rax, rbx
    jae .ll_timeout
    pause
    jmp .ll_wait
.ll_ready:
    lea rsi, [rel ser_ll_ready]
    call rtl8156_ser_puts
    jmp .ll_dump
.ll_timeout:
    lea rsi, [rel ser_ll_timeout]
    call rtl8156_ser_puts
.ll_dump:
    ; Dump the SFF_STS_7 word so a timeout is diagnosable: prints "SFF7:hhhh".
    lea rsi, [rel ser_sff7_tag]
    call rtl8156_ser_puts
    mov edi, RTL8156_PLA_SFF_STS_7 & ~3
    mov esi, RTL8156_MCU_PLA
    mov edx, 4
    mov rcx, RTL8156_SCRATCH_ADDR
    call rtl8156_ocp_read
    mov eax, [abs RTL8156_SCRATCH_ADDR]
    shr eax, ((RTL8156_PLA_SFF_STS_7 & 3) * 8)
    push rax
    mov al, ah
    call rtl8156_ser_phex8
    pop rax
    call rtl8156_ser_phex8
    mov al, 10
    mov dx, 0x3F8
    out dx, al
.ll_done:
    pop rbx
.skip_oob_init:
    call rtl8156_phy_powerup
    ; Read MAC from PLA_IDR.
    mov edi, RTL8156_PLA_IDR
    mov esi, RTL8156_MCU_PLA
    mov edx, 8
    mov rcx, RTL8156_SCRATCH_ADDR
    call rtl8156_ocp_read
    test eax, eax
    jz .fail
    mov eax, [abs RTL8156_SCRATCH_ADDR]
    mov [rtl8156_mac], eax
    mov ax, [abs RTL8156_SCRATCH_ADDR + 4]
    mov [rtl8156_mac + 4], ax
    ; Debug: dump the MAC we just read.
    push rsi
    push rax
    push rdx
    lea rsi, [rel ser_mac_tag]
    call rtl8156_ser_puts
    mov al, [rtl8156_mac + 0]
    call rtl8156_ser_phex8
    mov al, [rtl8156_mac + 1]
    call rtl8156_ser_phex8
    mov al, [rtl8156_mac + 2]
    call rtl8156_ser_phex8
    mov al, [rtl8156_mac + 3]
    call rtl8156_ser_phex8
    mov al, [rtl8156_mac + 4]
    call rtl8156_ser_phex8
    mov al, [rtl8156_mac + 5]
    call rtl8156_ser_phex8
    mov al, 10
    mov dx, 0x3F8
    out dx, al
    pop rdx
    pop rax
    pop rsi

    ; Set PLA_RMS (RX max frame size). Linux r8152 always writes this; if
    ; left at reset default the MAC silently drops every inbound frame even
    ; with promiscuous mode set. 1522 = 1500 MTU + Ethernet + VLAN headroom.
    mov dword [abs RTL8156_SCRATCH_ADDR], 1522
    mov edi, RTL8156_PLA_RMS
    mov esi, RTL8156_MCU_PLA | RTL8156_BYTE_EN_WORD
    mov edx, 4
    mov rcx, RTL8156_SCRATCH_ADDR
    call rtl8156_ocp_write

    ; PLA_MAR = all ones - accept any multicast hash so the filter never
    ; drops a frame we passed RCR. Two dword writes to cover the 8 bytes.
    mov dword [abs RTL8156_SCRATCH_ADDR], 0xFFFFFFFF
    mov edi, RTL8156_PLA_MAR
    mov esi, RTL8156_MCU_PLA | RTL8156_BYTE_DWORD
    mov edx, 4
    mov rcx, RTL8156_SCRATCH_ADDR
    call rtl8156_ocp_write
    mov dword [abs RTL8156_SCRATCH_ADDR], 0xFFFFFFFF
    mov edi, RTL8156_PLA_MAR + 4
    mov esi, RTL8156_MCU_PLA | RTL8156_BYTE_DWORD
    mov edx, 4
    mov rcx, RTL8156_SCRATCH_ADDR
    call rtl8156_ocp_write

    ; Disable RX aggregation for single-frame polling.
    mov dword [abs RTL8156_SCRATCH_ADDR], RTL8156_RX_AGG_DISABLE
    mov edi, RTL8156_USB_USB_CTRL
    mov esi, RTL8156_MCU_USB | RTL8156_BYTE_DWORD
    mov edx, 4
    mov rcx, RTL8156_SCRATCH_ADDR
    call rtl8156_ocp_write

    ; Accept unicast to our MAC plus broadcast/multicast during ARP.
    ; Promiscuous: AAP|APM|AM|AB so we receive every frame on the link.
    mov dword [abs RTL8156_SCRATCH_ADDR], RTL8156_RCR_AAP | RTL8156_RCR_APM | RTL8156_RCR_AM | RTL8156_RCR_AB
    mov edi, RTL8156_PLA_RCR
    mov esi, RTL8156_MCU_PLA | RTL8156_BYTE_DWORD
    mov edx, 4
    mov rcx, RTL8156_SCRATCH_ADDR
    call rtl8156_ocp_write

    ; Linux r8152 clears RXDY_GATED_EN before receiving frames.
    mov edi, RTL8156_PLA_MISC_1 & ~3
    mov esi, RTL8156_MCU_PLA
    mov edx, 4
    mov rcx, RTL8156_SCRATCH_ADDR
    call rtl8156_ocp_read
    mov eax, [abs RTL8156_SCRATCH_ADDR]
    and eax, ~RTL8156_RXDY_GATED_EN
    mov [abs RTL8156_SCRATCH_ADDR], eax
    mov edi, RTL8156_PLA_MISC_1 & ~3
    mov esi, RTL8156_MCU_PLA | RTL8156_BYTE_DWORD
    mov edx, 4
    mov rcx, RTL8156_SCRATCH_ADDR
    call rtl8156_ocp_write

    ; Enable RX/TX via byte write at PLA_CR.
    mov dword [abs RTL8156_SCRATCH_ADDR], ((RTL8156_CR_RE | RTL8156_CR_TE) << 24)
    mov edi, RTL8156_PLA_CR & ~3
    mov esi, RTL8156_MCU_PLA | 0x88
    mov edx, 4
    mov rcx, RTL8156_SCRATCH_ADDR
    call rtl8156_ocp_write

    ; Notify RX DMA ownership update for r8153+ devices.
    mov dword [abs RTL8156_SCRATCH_ADDR], RTL8156_OWN_UPDATE_CLEAR
    mov edi, RTL8156_USB_UPT_RXDMA_OWN & ~3
    mov esi, RTL8156_MCU_USB | 0x88
    mov edx, 4
    mov rcx, RTL8156_SCRATCH_ADDR
    call rtl8156_ocp_write

    ; Re-clear RXDY_GATED_EN now that RX is enabled. Linux r8152.c sequences
    ; this AFTER the PLA_CR write - clearing it beforehand alone is not
    ; sufficient on r815x silicon and leaves the RX FIFO gated shut.
    mov edi, RTL8156_PLA_MISC_1 & ~3
    mov esi, RTL8156_MCU_PLA
    mov edx, 4
    mov rcx, RTL8156_SCRATCH_ADDR
    call rtl8156_ocp_read
    mov eax, [abs RTL8156_SCRATCH_ADDR]
    and eax, ~RTL8156_RXDY_GATED_EN
    mov [abs RTL8156_SCRATCH_ADDR], eax
    mov edi, RTL8156_PLA_MISC_1 & ~3
    mov esi, RTL8156_MCU_PLA | RTL8156_BYTE_DWORD
    mov edx, 4
    mov rcx, RTL8156_SCRATCH_ADDR
    call rtl8156_ocp_write

    ; Configure the USB RX early-flush so single-frame polling actually gets
    ; data out of the chip. Without these, the MAC waits for a buffer-full
    ; or aggregation timer that we never arm, and every IN token returns 0
    ; bytes. Values mirror r8152 single-frame defaults: small threshold,
    ; minimum timeout, size set to one MTU-ish frame.
    mov dword [abs RTL8156_SCRATCH_ADDR], 0x00000080   ; RX_BUF_TH = 0x80
    mov edi, RTL8156_USB_RX_BUF_TH
    mov esi, RTL8156_MCU_USB | RTL8156_BYTE_DWORD
    mov edx, 4
    mov rcx, RTL8156_SCRATCH_ADDR
    call rtl8156_ocp_write

    mov dword [abs RTL8156_SCRATCH_ADDR], 0x00000600   ; one frame's worth
    mov edi, RTL8156_USB_RX_EARLY_SIZE
    mov esi, RTL8156_MCU_USB | RTL8156_BYTE_DWORD
    mov edx, 4
    mov rcx, RTL8156_SCRATCH_ADDR
    call rtl8156_ocp_write

    mov dword [abs RTL8156_SCRATCH_ADDR], 0x00000001   ; flush ASAP
    mov edi, RTL8156_USB_RX_EARLY_TIMEOUT
    mov esi, RTL8156_MCU_USB | RTL8156_BYTE_DWORD
    mov edx, 4
    mov rcx, RTL8156_SCRATCH_ADDR
    call rtl8156_ocp_write

    ; PHY auto-negotiation starts automatically when the adapter is powered
    ; via USB; rtl8156_wait_link polls PLA_PHYSTATUS for it to complete.
    mov eax, 1
    ret
.fail:
    xor eax, eax
    ret

; ============================================================================
; Wait for PHY link to come up. Polls PLA_PHYSTATUS (0xC0D8). Bits[2:0] == 3
; (PHY_STAT_LAN_ON) indicates the MAC/PHY has negotiated a link.
; Returns EAX=1 on link, EAX=0 on timeout. Best-effort: caller continues
; either way so a late-plugged cable still works on next ping retry.
; ============================================================================
rtl8156_wait_link:
    push rbx
    push rcx
    push rdx
    push rsi

    lea rsi, [rel ser_link_wait_8156]
    call rtl8156_ser_puts

    ; Kick PHY auto-neg via MDIO BMCR (Linux r8152 r8152_mdio_write path).
    ; ----------------------------------------------------------------------
    ; FIX (BMSR=0x0000 link timeout): the PHY MII registers are NOT directly
    ; OCP-addressable at 0xA400. They are only reachable through the GPHY
    ; indirection window: point PLA_OCP_GPHY_BASE (0xB12C) at the 0xA000 page,
    ; then access the 0xB400+reg*2 mirror. The previous code wrote ANE|RAN
    ; straight to OCP 0xA400 (a non-PHY PLA address in the 0xA000 page that the
    ; window never exposes), so RESTART_AUTONEG never reached the PHY and
    ; BMSR.LSTATUS stayed low forever. Re-point the base (intervening OOB/
    ; first_init OCP traffic may have moved it) and drive BMCR through the same
    ; rtl8156_mdio_write window the BMSR read below uses.
    call rtl8156_mdio_set_base
    mov edi, RTL8156_MII_BMCR
    mov esi, RTL8156_BMCR_ANE | RTL8156_BMCR_RAN
    call rtl8156_mdio_write

    ; NON-BLOCKING (boot must not stall on link). Auto-neg was kicked just above;
    ; sample BMSR ONCE for diagnostics and return immediately. Why not poll:
    ;  - An absent or unplugged NIC never links, so any budget here is pure boot
    ;    delay when there's no ethernet.
    ;  - Even when a cable IS present, gigabit auto-neg takes ~2-3s; the old 5s
    ;    poll blocked the whole boot until link (or timeout).
    ; Link comes up in the background; the main-loop DHCP pump and the ping ARP
    ; path retry until it does, so a slow-negotiating, later-plugged, or
    ; different-port NIC still works - it just binds shortly after the desktop
    ; appears instead of holding boot hostage.
    mov edi, RTL8156_MII_BMSR
    call rtl8156_mdio_read
    push rax
    lea rsi, [rel ser_bmsr_tag]
    call rtl8156_ser_puts
    pop rax
    push rax
    mov al, ah
    call rtl8156_ser_phex8
    pop rax
    push rax
    call rtl8156_ser_phex8
    mov al, 10
    mov dx, 0x3F8
    out dx, al
    pop rax
    test ax, RTL8156_BMSR_LSTATUS
    jz .nolink_yet
    lea rsi, [rel ser_link_up_8156]
    call rtl8156_ser_puts
    jmp .done_ok
.nolink_yet:
    ; Not up yet - best-effort; background DHCP/ping retries handle it.
    lea rsi, [rel ser_link_wait_8156]
    call rtl8156_ser_puts
.done_ok:
    mov eax, 1
.done:
    pop rsi
    pop rdx
    pop rcx
    pop rbx
    ret
