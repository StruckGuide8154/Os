section .data
align 8
v_handle:           dq 0
v_systab:           dq 0
v_bs:               dq 0
v_conout:           dq 0
v_gop:              dq 0
v_fb:               dq 0
v_scrw:             dd 0
v_scrh:             dd 0
v_pitch_pixels:     dd 0
v_pixfmt:           dd 0
align 8
v_fbsize:           dq 0
g_trace_stall_us:   dd 130000                 ; 130 ms per trace step
v_enable_sppapp:    db 0                      ; 0 = SPP/APP polling OFF (they hang)
align 8
v_mx:               dd 400
v_my:               dd 300
v_prev_mx:          dd 400
v_prev_my:          dd 300

; Two slots per protocol: [0]=LocateProtocol, [1]=handle-enum
v_spp:              dq 0, 0
v_spp_ok:           db 0, 0
v_app:              dq 0, 0
v_app_ok:           db 0, 0
align 8
v_usb_io:           dq 0                      ; slot 4: USB IO Protocol iface
v_usb_ok:           db 0
v_usb_ep:           db 0                      ; IN endpoint address (with 0x80 bit)
v_usb_interval:     db 0
v_usb_iface_num:    db 0
v_usb_epattr:       db 0
v_usb_numep:        db 0
align 2
v_usb_maxpkt:       dw 0
align 8
v_usb_async_ret:    dq 0
usb_async_buf:      times 16 db 0
usb_async_report:   dd 0
usb_async_hits:     dd 0
v_async_seen:       dd 0
v_usb_found:        dd 0
v_usb_disc_ret:     dq 0
v_state:            db 0, 0, 0, 0, 0
align 8
v_lastret:          dq 0, 0, 0, 0, 0          ; last GetState/transfer return per slot
v_hits:             dd 0, 0, 0, 0, 0          ; success count per slot
v_frame:            dd 0

; USB descriptors + scratch
align 8
usb_if_desc:        times 16 db 0             ; EFI_USB_INTERFACE_DESCRIPTOR (9 bytes)
usb_ep_desc:        times 16 db 0             ; EFI_USB_ENDPOINT_DESCRIPTOR  (7 bytes)
usb_report_buf:     times 16 db 0             ; HID boot mouse report
usb_xfer_status:    dd 0
usb_setup_pkt:      times 8 db 0              ; EFI_USB_DEVICE_REQUEST
v_last_report:      dd 0                      ; last *nonzero* 4 bytes of report
drb_tmp:            dd 0                      ; scratch for draw_report_bars

; Scratch buffers for number formatting
align 8
num_scratch:        times 32 db 0             ; ASCII reverse digits
num_buf:            times 64 dw 0             ; UCS-2 output

; ConOut strings (UCS-2)
align 2
s_banner:       ustr "Grit UEFI Mouse Probe ZULU -- stays in UEFI, no kernel"
s_crlf:         ustr ""        ; OutputString interprets \r\n via CR/LF chars: use explicit
s_gop_res:      ustr "GOP: "
s_x:            ustr " x "
s_pitch:        ustr "  pitch="
s_fb:           ustr "  fb=0x"
s_pixfmt:       ustr "PixelFormat="
s_fbsize:       ustr "  fbsize=0x"
s_probing_spp:  ustr "Probing EFI_SIMPLE_POINTER_PROTOCOL ..."
s_probing_app:  ustr "Probing EFI_ABSOLUTE_POINTER_PROTOCOL ..."
s_main_hdr:     ustr "--- Live status: ret codes per slot, hit counts, cursor pos. WIGGLE INPUT ---"
s_line_ret:     ustr "ret  0=0x"
s_line_hit:     ustr "hits 0="
s_line_pos:     ustr "mx,my="
s_space:        ustr "  "
s_comma:        ustr ","
s_pad:          ustr "                    "   ; trailing spaces to clear stale digits
s_r_spp_loc_ok:    ustr "  [OK] SPP LocateProtocol  iface=0x"
s_r_spp_loc_fail:  ustr "  [..] SPP LocateProtocol  status=0x"
s_r_spp_enum_n:    ustr "  [..] SPP handles found="
s_r_spp_enum_ok:   ustr "  [OK] SPP via OpenProtocol iface=0x"
s_r_spp_enum_fail: ustr "  [..] SPP enum: no usable handle"
s_r_app_loc_ok:    ustr "  [OK] AbsolutePointer LocateProtocol iface=0x"
s_r_app_loc_fail:  ustr "  [..] AbsolutePointer LocateProtocol status=0x"
s_r_app_enum_n:    ustr "  [..] AbsolutePointer handles found="
s_r_app_enum_ok:   ustr "  [OK] AbsolutePointer via OpenProtocol iface=0x"
s_r_app_enum_fail: ustr "  [..] AbsolutePointer enum: no usable handle"
s_probing_usb:     ustr "Probing EFI_USB_IO_PROTOCOL ..."
s_r_usb_n:         ustr "  [..] USB_IO handles found="
s_r_usb_ok:        ustr "  [OK] USB HID mouse: ep=0x"
s_r_usb_fail:      ustr "  [..] USB_IO: no HID mouse found"
s_r_usb_setproto:  ustr "  [..] USB SET_PROTOCOL boot status=0x"
s_r_usb_async:     ustr "  [..] USB AsyncInterruptTransfer rc=0x"
s_d_iface:         ustr "  desc: iface="
s_d_ep:            ustr " ep="
s_d_attr:          ustr " attr="
s_d_mps:           ustr " maxpkt="
s_d_ivl:           ustr " ivl="
s_r_usb_disc:      ustr "  [..] DisconnectController rc=0x"
s_readpause:       ustr ">>> PAUSING 20s - photograph the desc:/rc lines above. Then WIGGLE MOUSE <<<"
s_live_label:      ustr "spp_loc spp_enum app_loc app_enum usb  mx,my"
s_arrow:           ustr " -> "

; Override s_crlf with actual CR LF chars (the macro above can't emit \r\n
; for a non-printable code, so we patch with raw words)
align 2
s_crlf_real:
    dw 13, 10, 0

; --- GUIDs ---
align 8
guid_gop:
    dd EFI_GOP_GUID_D1
    dw 0x23dc, 0x4a38
    db 0x96, 0xfb, 0x7a, 0xde, 0xd0, 0x80, 0x51, 0x6a

; EFI_SIMPLE_POINTER_PROTOCOL_GUID
; 31878c87-0b75-11d5-9a4f-0090273fc14d
guid_spp:
    dd EFI_SPP_GUID_D1
    dw 0x0b75, 0x11d5
    db 0x9a, 0x4f, 0x00, 0x90, 0x27, 0x3f, 0xc1, 0x4d

; EFI_ABSOLUTE_POINTER_PROTOCOL_GUID
; 8D59D32B-C655-4AE9-9B15-F25904992A43
guid_app:
    dd EFI_APP_GUID_D1
    dw 0xc655, 0x4ae9
    db 0x9b, 0x15, 0xf2, 0x59, 0x04, 0x99, 0x2a, 0x43

; EFI_USB_IO_PROTOCOL_GUID
; 2B2F68D6-0CD2-44CF-8E8B-BBA20B1B5B75
guid_usbio:
    dd EFI_USBIO_GUID_D1
    dw 0x0cd2, 0x44cf
    db 0x8e, 0x8b, 0xbb, 0xa2, 0x0b, 0x1b, 0x5b, 0x75

times (HDR_SZ + TEXT_RAW - ($ - $$)) db 0

; .reloc
    dd 0x1000, 12
    dw 0, 0

times (HDR_SZ + TEXT_RAW + RELOC_FSZ - ($ - $$)) db 0
