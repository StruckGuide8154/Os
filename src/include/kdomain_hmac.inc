%ifndef KDOMAIN_HMAC_INC
%define KDOMAIN_HMAC_INC
; ============================================================================
; NexusOS - One domain-separated kernel HMAC primitive (security_todo.md §13)
;
; Three kernel anti-tamper tags all derive a short MAC from the same secret,
; [rel kernel_canary], XORed with a couple of context words and truncated:
;
;   * CPI callback signing  (cpi_sign_callback / cpi_verify_callback) —
;       low16(kernel_canary ^ &window ^ field_offset), stamped into bits[48:64]
;       of a stored callback pointer.
;   * Cap-mask authenticator (cap_mask_sign + the dispatcher's inline verify) —
;       low8(kernel_canary ^ slot ^ mask ^ CAP_HMAC_DOMAIN), stored beside the
;       1-byte mask in slot_cap_hmac[].
;   * WIN_OFF_USER_ARG tag   (sc_wm_set_user_arg / sc_wm_get_user_arg) —
;       low16(kernel_canary ^ &window), stamped into bits[48:64] of user_arg.
;
; Before this convergence those were three look-alike copies; a fourth user
; could silently reuse a domain. They are now one macro (KHMAC_TAG) plus one
; domain-separation table below, so an auditor sees a single scheme.
;
; --- DOMAIN SEPARATION TABLE ------------------------------------------------
; One named domain constant per user, XORed into the accumulator so a tag
; forged for one user can never be replayed into another. CPI and USER_ARG
; historically carried NO domain byte and their in-memory tags are already
; stamped at runtime; XOR with 0 is the identity, so defining their domains as
; 0 keeps every previously stamped tag bit-for-bit valid (this is a refactor,
; not a value change). CAP_MASK keeps its established 0x5C so the cap
; authenticator value is likewise unchanged. A genuinely new (fourth) user
; MUST add a fresh non-zero, distinct constant here.
KDOM_CPI        equ 0x00    ; CPI callback tag (value-preserving: was domainless)
KDOM_USER_ARG   equ 0x00    ; WIN_OFF_USER_ARG tag (value-preserving: was domainless)
KDOM_CAP_MASK   equ 0x5C    ; cap-mask authenticator (== legacy CAP_HMAC_DOMAIN)

; --- THE PRIMITIVE ----------------------------------------------------------
; KHMAC_TAG acc, acc32, trunc, in0, in1, domain
;
;   acc    : 64-bit scratch GPR that accumulates the MAC and, on exit, holds
;            the zero-extended tag in its low bits. Caller owns its save/restore.
;   acc32  : acc's 32-bit name (ecx / edx / r9d ...). NASM has no portable way
;            to derive it from %1 (legacy regs aren't <name>+"d"), so it is
;            named explicitly; it MUST be the 32-bit alias of acc.
;   trunc  : acc's sub-register naming the retained width — cl/dl/r9b... for an
;            8-bit tag, cx/dx/r9w... for a 16-bit tag. MUST be a sub-register
;            of acc.
;   in0    : first 64-bit context operand to mix (already materialised by the
;            caller, e.g. a struct address or a movzx'd byte input).
;   in1    : second 64-bit context operand, or the literal token 0 to mix only
;            one (CPI/CAP mix two; USER_ARG mixes one).
;   domain : a KDOM_* constant from the table above.
;
; Emits exactly: acc = kernel_canary; acc ^= in0; [acc ^= in1;] [acc ^= domain;]
;                acc32 = zero_extend(trunc).
; Note acc ^= domain is elided when domain==0 so the value-preserving CPI and
; USER_ARG cases emit byte-identical code to their hand-written originals; the
; domain XOR is real (one instruction) only for CAP_MASK. This reproduces each
; site's prior arithmetic so existing stamped tags still verify.
%macro KHMAC_TAG 6
    mov %1, [rel kernel_canary]
    xor %1, %4
%ifnidn %5, 0
    xor %1, %5
%endif
%if %6 != 0
    xor %1, %6
%endif
    movzx %2, %3
%endmacro

%endif ; KDOMAIN_HMAC_INC
