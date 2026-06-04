; --- Data Sections ---
section .data
align 8
l3_app_blob_copy_cap_guard: dq L3_APP_BLOB_COPY_CAP
app_blob_base_v:     dq 0
app_blob_end_v:      dq 0
app_blob_size_v:     dq 0
l3_app_arena_base_v: dq APP_DATA_ADDR
l3_app_arena_size_v: dq (MAX_WINDOWS * APP_SLOT_SIZE)
%ifdef ENABLE_DEBUG_SERIAL
xcpy_calls:          dd 0          ; DEBUG: limit XCPY immediate dump to first 3 slot copies
%endif

; --- BSS Section (Always last) ---
section .bss
; 128 KiB alignment guarantees the MAX_WINDOWS * 8 KiB = 96 KiB array fits
; inside a single 2 MiB PDE, which lets l3_install_syscall_stack_pt swap
; that PDE for a single 4 KiB page table.
alignb 16
global l3_wx_manifest_ver
global l3_wx_code_start
global l3_wx_code_end
global l3_slot_live
global l3_slot_ustack_off
global l3_slot_code_slide
l3_slot_live:        resq MAX_WINDOWS
l3_wx_manifest_ver: resq MAX_WINDOWS
l3_wx_code_start:   resq MAX_WINDOWS
l3_wx_code_end:     resq MAX_WINDOWS
; Per-slot user-stack-top in-slot offset (set by l3_randomize_user_stack_top
; on every slot (re)load). Zero = uninitialized, falls back to legacy fixed top.
l3_slot_ustack_off: resq MAX_WINDOWS
; Per-slot code slide (set by l3_randomize_code_slide on every slot (re)load).
; Page-aligned, in [0, L3_APP_BLOB_PLACE_CAP - blob_size]. The blob is copied
; to slot_base + slide, so a code-pointer leak in one slot only reveals that
; slot's gadget addresses ??? sibling slots have independent slides.
l3_slot_code_slide: resq MAX_WINDOWS
; Code-range integrity hashing (security_todo.md ??12). l3_code_hash[slot] holds
; the FNV-1a hash of the slot's executable (X) code-range bytes, captured the
; first time l3_apply_wx_policy commits a valid v1 manifest for the slot
; (hash-on-install). l3_code_hash_valid[slot] != 0 marks the baseline as live.
; pit_handler periodically calls l3_code_hash_verify_all; any mismatch means an
; unintended W landed on a code page (e.g. an undiscovered JIT-alias bug
; mutated executable bytes) -> kernel_panic_canary. Both are cleared on slot
; recycle in l3_copy_app_blob_to_slot so the next tenant re-baselines.
global l3_code_hash
global l3_code_hash_valid
l3_code_hash:       resq MAX_WINDOWS
l3_code_hash_valid: resb MAX_WINDOWS
alignb 8
; Per-slot kernel-only identity key (security_todo.md ??10). l3_slot_key[slot]
; holds FNV-1a(kernel_canary || slot_id || boot_nonce), derived by
; l3_derive_slot_key on every slot (re)init from l3_copy_app_blob_to_slot. This
; lives in kernel BSS ??? OUTSIDE the ring-3 app arena ??? so an app can never read
; or forge its own key; a future HMAC-this-data syscall is the only intended
; egress, and even then only the MAC leaves the kernel, never the key.
global l3_slot_key
l3_slot_key:        resq MAX_WINDOWS
; One-shot boot nonce mixed into every slot key, seeded once from RDTSC^RDRAND
; by l3_boot_nonce_ensure. Kernel-only; never exposed to ring 3.
l3_boot_nonce:      resq 1
l3_boot_nonce_done: resb 1
alignb 16
global l3_runtime
; Keep this in sync with L3_RT_SIZE above. A smaller allocation corrupts
; adjacent state as soon as multiple ring-3 callbacks run.
l3_runtime:          resb (MAX_WINDOWS * L3_RT_SIZE)

section .text
