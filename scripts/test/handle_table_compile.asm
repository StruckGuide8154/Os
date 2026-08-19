; Standalone syntax/relocation harness for src/kernel/proc/handle_table.inc.
; It deliberately uses the repository's real constants.inc so ABI constant drift
; is caught by the same assembly pass. No runtime behavior is provided here.

bits 64
%include "constants.inc"

section .data
align 8
l3_app_arena_base_v: dq APP_DATA_ADDR

section .text
%include "src/kernel/proc/handle_table.inc"
