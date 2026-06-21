# Trace 09 - `SYS_WM_CREATE` → Window Pool Slot → First Paint

## Entry

User app calls `SYS_WM_CREATE(x, y, w, h, title_ptr)` - syscall rax=8, rdi=x, rsi=y, rdx=w, r10=h, r8=title.

## Step-by-step

### Phase 1: syscall validation

| # | File:Line | Action |
|---|---|---|
| 1 | syscall.asm `.sc_wm_create` | bounds check: x,y,w,h within scr; w/h > 0 |
| 2 | | `call sc_validate_callback_target` if title carries handler ptrs (it doesn't directly) |
| 3 | | `call wm_create_window_ex(rdi=x, rsi=y, edx=w, ecx=h, r8=title)` |

### Phase 2: wm_create_window_ex (`kernel/gui/window.asm`)

| # | Action |
|---|---|
| 4 | choose a randomized start slot in `1..MAX_WINDOWS-1`, then scan/wrap through `window_pool` for a slot with `WIN_OFF_FLAGS & WF_ACTIVE == 0` (`-NoMemRandom` uses deterministic slot 1 first) |
| 5 | If none: return -1 (full) |
| 6 | Slot pointer = `WINDOW_POOL_ADDR + slot_idx * WINDOW_STRUCT_SIZE` |
| 7 | Write fields: WIN_OFF_X/Y/W/H, WIN_OFF_TITLE (memcpy 32 bytes from r8), WIN_OFF_OWNER_PID = current process, WIN_OFF_FLAGS = WF_ACTIVE \| WF_VISIBLE |
| 8 | WIN_OFF_CLICKFN/KEYFN/DRAWFN = 0 (handlers installed later by `SYS_WM_HANDLERS`) |
| 9 | Set `wm_focused_window = slot_idx` |
| 10 | Set `scene_dirty = 1` |
| 11 | Return slot_idx in rax |

### Phase 3: app installs handlers

App calls `SYS_WM_HANDLERS(window_idx, click_fn, key_fn, draw_fn)` - syscall validation rejects out-of-range idx (kernel-write-primitive guard, syscall.asm:480). Each callback validated via `sc_validate_callback_target` (must be in app's L3 code arena). Stored to `WIN_OFF_CLICKFN/KEYFN/DRAWFN`.

### Phase 4: render frame picks up window

| # | File:Line | Action |
|---|---|---|
| 12 | main render-loop | `call wm_draw_all_windows` |
| 13 | window.asm | for each WF_ACTIVE slot ordered by Z: `call wm_draw_window(slot_ptr)` |
| 14 | wm_draw_window | save r13/r14/r15 (MEMORY.md #7); compute titlebar rect; `fill_rect` titlebar color |
| 15 | wm_draw_window | `draw_string` title with rdx=title_ptr, ecx=COLOR_TEXT_WHITE, r8d=titlebar_color (MEMORY.md #6 fix; Round 2 verified order correct) |
| 16 | wm_draw_window | `draw_rect_outline(x, y, w, h, border_color)` - Round 2 fix made all 4 edges draw correctly |
| 17 | wm_draw_window | `fill_rect` content rect with COLOR_WINDOW_BG |
| 18 | wm_draw_window | if WIN_OFF_DRAWFN ≠ 0: `call [WIN_OFF_DRAWFN]` - app draws inside content rect via syscalls |

### Phase 5: cursor + flip

(See Trace 04.)

## Audit-pass guarantees

- Window slots can't be aliased: index bounds checked before pointer arith.
- Callback ptrs validated to caller's code arena → ring-3 can't install kernel addresses.
- `wm_draw_window` preserves r13-r15 (MEMORY.md #7).
- `tb_handle_click` (and similar) use `mov rax, 1` AFTER pop sequence, not push/pop rax around it (MEMORY.md #4 verified Round 2).

## Failure modes

- All slots taken → -1 returned. App must handle.
- Crash inside callback → kernel crash (no per-app fault recovery).
- Title > 32 bytes → silently truncated.

## Invariants

- WF_ACTIVE bit set ↔ slot in use; cleared by `wm_close_window`.
- Slot index ∈ [0, MAX_WINDOWS).
- `wm_focused_window == -1` when no active window.
- Callbacks stored only for WF_ACTIVE slots (validation in `.sc_wm_handlers`).
