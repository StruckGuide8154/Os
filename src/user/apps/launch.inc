MEDIA_PLAYER_BAR_H equ 26

; ----------------------------------------------------------------------------
; Named constants for the launcher / L3 selftest. Values copied verbatim from
; the original inline literals.
; ----------------------------------------------------------------------------
LAUNCH_COL_L3_PANEL equ 0x0000AA44   ; L3 selftest result panel rect/text color (green, ARGB)
LAUNCH_NBA1_MAGIC   equ 0x3141424E   ; 'NBA1' little-endian file magic (Grit video clip)

%include "src/user/apps/launch_handlers.inc"
%include "src/user/apps/launch_dispatch.inc"
%include "src/user/apps/launch_open.inc"
%include "src/user/apps/launch_kopen.inc"
