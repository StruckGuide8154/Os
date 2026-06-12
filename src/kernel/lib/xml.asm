; ============================================================================
; Grit XML parser - compact DOM subset
; ============================================================================
bits 64

global xml_parse
global xml_root
global xml_tag
global xml_tag_name
global xml_first_child
global xml_next_sibling
global xml_parent
global xml_attr
global xml_text
global xml_free
global xml_last_error
global xml_node_count
global xml_text_run
global xml_text_runs
global xml_namespace
global xml_node_namespace
global xml_entity_value

XML_MAX_NODES equ 8192
XML_NODE_SIZE equ 32
XML_MAX_DEPTH equ 64
XML_MAX_ENT   equ 64
XML_NIL       equ 0xFFFFFFFF

N_TAG_OFF equ 0
N_TAG_LEN equ 4
N_PARENT  equ 8
N_CHILD   equ 12
N_SIB     equ 16
N_TAG_END equ 20
N_CEND    equ 24      ; offset of '<' of this element's closing tag
N_PEND    equ 28      ; offset just past the whole element

section .bss
alignb 16
; --- Per-slot parser state (security: XML DOM is isolated per app slot) ------
; The whole DOM + parse-time scratch below forms ONE contiguous "live" context
; that the parser code operates on directly (unchanged). To make this per-slot,
; the live block is swapped against a per-slot save area (xml_state_pool) at
; every public entry point, keyed off the calling slot (r15) via xml_switch_to.
; Effect: each app slot keeps its own persistent DOM ??? one app re-parsing can
; never clobber or disclose another app's parsed tree.
xml_state_begin:
xml_nodes:    resb XML_MAX_NODES * XML_NODE_SIZE
xml_node_n:   resq 1
xml_root_idx: resd 1
xml_err:      resd 1
xml_err_off:  resq 1
xml_doc_live: resd 1
xml_base:     resq 1
xml_end:      resq 1
xml_attr_tag_end: resd 1
xml_stack:    resd XML_MAX_DEPTH
xml_stack_n:  resd 1
xml_ent_name_off: resd XML_MAX_ENT
xml_ent_name_len: resd XML_MAX_ENT
xml_ent_val_off:  resd XML_MAX_ENT
xml_ent_val_len:  resd XML_MAX_ENT
xml_ent_n:        resd 1
xml_ns_scratch:   resb 64
xml_state_end:
XML_STATE_SIZE equ xml_state_end - xml_state_begin

alignb 16
; One save area per slot. BSS-zero = "doc_live==0" = empty DOM, the correct
; initial state for a slot that has never parsed (xml_root reports none).
xml_state_pool: resb XML_STATE_SIZE * APP_SLOT_COUNT
; Slot whose context is currently live. BSS-zero = slot 0, which matches the
; zeroed (empty) live block at boot, so no separate "uninitialized" sentinel is
; needed: the very first switch saves slot 0's empty context and loads the
; target's (also empty) one.
xml_active_slot: resd 1

%include "src/kernel/lib/xml_access.inc"
%include "src/kernel/lib/xml_parse.inc"
%include "src/kernel/lib/xml_query.inc"
