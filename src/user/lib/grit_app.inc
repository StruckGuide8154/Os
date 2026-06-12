%ifndef GRIT_APP_INC
%define GRIT_APP_INC

; ============================================================================
; Grit v3.0 - User App Kit
; Shared include for ring-3 apps. Pulls in the syscall wrappers and the shared
; window/constants definitions that callback code usually needs.
; ============================================================================

%include "constants.inc"
%include "syscall_user.inc"
%include "grit_fs.inc"

; Callback ABI
; ------------
; draw/click handlers:
;   RDI = pointer to the shadow window struct in the app slot arena
; click handlers:
;   RSI = mouse X
;   RDX = mouse Y
; key handlers:
;   RSI = key code / translated character value
;
; Handlers execute in ring 3 and must return with RET unless they terminate the
; callback explicitly through SYS_APP_DONE.

%endif
