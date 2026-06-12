# GritOS Data Layout Reference

This document covers the important live structures and in-memory layouts that
maintainers frequently need when debugging bugs across subsystem boundaries.

Primary sources:

- `C:\Users\user\Documents\new\src\include\structs.inc`
- `C:\Users\user\Documents\new\src\kernel\gui\window.asm`
- `C:\Users\user\Documents\new\src\kernel\proc\process.asm`
- `C:\Users\user\Documents\new\src\kernel\proc\usermode.asm`
- `C:\Users\user\Documents\new\src\kernel\fs\fat16.asm`

## Window Pool Layout

Owner:
- `src/kernel/gui/window.asm`

Base:
- `WINDOW_POOL_ADDR`

Count:
- `MAX_WINDOWS`

Stride:
- `WINDOW_STRUCT_SIZE = 256`

Window offsets actually used by the kernel/window manager:

| Offset | Field | Notes |
|---|---|---|
| `0` | `WIN_OFF_ID` | slot/window id |
| `8` | `WIN_OFF_X` | window X |
| `16` | `WIN_OFF_Y` | window Y |
| `24` | `WIN_OFF_W` | width |
| `32` | `WIN_OFF_H` | height |
| `40` | `WIN_OFF_FLAGS` | `WF_*` bits |
| `48` | `WIN_OFF_TITLE` | inline title storage |
| `112` | `WIN_OFF_DRAWFN` | draw callback |
| `120` | `WIN_OFF_KEYFN` | key callback |
| `128` | `WIN_OFF_CLICKFN` | click callback |
| `136` | `WIN_OFF_APPDATA` | per-window app slot base |

Important notes:

- The live window layout in `window.asm` is the authoritative runtime layout.
- `structs.inc` also defines a `window_t`, but it reflects an older pointer-style
  model and should not be treated as the live window-pool ABI.
- Ring-3 apps do not receive the live window object. They receive a shadow copy
  in their slot arena.

## Window Flags

From `constants.inc`:

| Flag | Value | Meaning |
|---|---:|---|
| `WF_VISIBLE` | `0x01` | visible |
| `WF_FOCUSED` | `0x02` | focused |
| `WF_DRAGGING` | `0x04` | drag in progress |
| `WF_MINIMIZED` | `0x08` | minimized |
| `WF_ACTIVE` | `0x10` | slot in use |

## Process Record Layout

Owner:
- `src/kernel/proc/process.asm`

Definition source:
- `src/include/structs.inc`

Base:
- `PROCESS_POOL = 0x220000`

Stride:
- `512 bytes`

Key fields:

| Offset | Field | Meaning |
|---|---|---|
| `0x00` | `rax` | saved GP register |
| `0x38` | `rsp` | saved user RSP |
| `0x80` | `rip` | saved RIP |
| `0x88` | `rflags` | saved RFLAGS |
| `0x90` | `cr3` | page-table pointer slot |
| `0x98` | `state` | `0=EMPTY, 1=READY, 2=RUNNING, 3=SLEEPING, 4=TERMINATED` |
| `0x9C` | `id` | process id |
| `0xA0` | `win_id` | owning/associated window id |
| `0xA4` | `slot` | app-slot index |
| `0xA8` | `cs` | code selector |
| `0xB0` | `ss` | stack selector |
| `0xB8` | `kernel_rsp` | kernel stack pointer |

## L3 Runtime Frame

Owner:
- `src/kernel/proc/usermode.asm`
- `src/kernel/proc/syscall.asm`

Base:
- `l3_runtime`

Stride:
- `L3_RT_SIZE = 128`

Fields:

| Offset | Field | Meaning |
|---|---|---|
| `0` | `L3_RT_ENTRY` | callback target |
| `8` | `L3_RT_ARG0` | arg0 |
| `16` | `L3_RT_ARG1` | arg1 |
| `24` | `L3_RT_ARG2` | arg2 |
| `32` | `L3_RT_KERNEL_RSP` | kernel return stack |
| `40` | `L3_RT_KERNEL_RFLAGS` | saved kernel flags |
| `48` | `L3_RT_USER_RSP` | ring-3 stack |
| `56` | `L3_RT_USER_RIP` | ring-3 instruction pointer |
| `64` | `L3_RT_USER_RFLAGS` | ring-3 flags |
| `72` | `L3_RT_APP_BASE` | slot base |
| `80` | `L3_RT_SYSCALL_NUM` | last syscall number |
| `88` | `L3_RT_USER_RDX` | saved RDX |
| `96` | `L3_RT_USER_R8` | saved R8 |
| `104` | `L3_RT_USER_R9` | saved R9 |
| `112` | `L3_RT_USER_R10` | saved R10 |
| `120` | `L3_RT_SLOT` | slot index |

Related layout constants:

- `L3_APP_CODE_OFF = 512`
- `L3_SHADOW_WIN_OFF = APP_SLOT_SIZE - 512`

Terminal-specific context offsets inside the slot arena:

| Offset | Field |
|---|---|
| `160` | `TERM_CTX_X` |
| `168` | `TERM_CTX_Y` |
| `176` | `TERM_CTX_W` |
| `184` | `TERM_CTX_H` |

## App Slot Layout

Owner:
- `src/kernel/proc/usermode.asm`

Each app slot is `APP_SLOT_SIZE = 0x100000`.

Practical layout:

- slot base: app-owned code/data area
- `+512`: copied-in code for translated callback blobs such as Terminal
- near slot end: shadow window struct at `L3_SHADOW_WIN_OFF`
- top of slot: space reserved for the `SYS_APP_DONE` trampoline blob

## FAT16 Driver Layout

Owner:
- `src/kernel/fs/fat16.asm`

### Directory entry layout

| Offset | Field |
|---|---|
| `0` | `DIR_NAME` |
| `8` | `DIR_EXT` |
| `11` | `DIR_ATTR` |
| `20` | `DIR_FIRST_CLUS_HI` |
| `26` | `DIR_FIRST_CLUS_LO` |
| `28` | `DIR_FILE_SIZE` |
| `32` | `DIR_ENTRY_SIZE` |

Attributes:

| Name | Value |
|---|---:|
| `ATTR_READ_ONLY` | `0x01` |
| `ATTR_HIDDEN` | `0x02` |
| `ATTR_SYSTEM` | `0x04` |
| `ATTR_VOLUME_ID` | `0x08` |
| `ATTR_DIRECTORY` | `0x10` |
| `ATTR_ARCHIVE` | `0x20` |
| `ATTR_LFN` | `0x0F` |

### FAT16 cache layout

| Region | Purpose |
|---|---|
| `FAT16_SECTOR_BUF` | single-sector scratch buffer |
| `FAT16_FAT_CACHE` | FAT table cache |
| `FAT16_ROOT_CACHE` | root/current directory cache |
| `FAT16_FILE_BUF` | file-read staging buffer |
| `FAT16_DIR_CACHE` | directory listing cache |

### Opaque handle rule

The return value from `fat16_get_entry` / `SYS_FS_ENTRY` should be treated as an
opaque FAT16 handle, not as user-owned memory. Current syscall validation
enforces that it points at an aligned entry inside `FAT16_ROOT_CACHE`.

For usermode, `SYS_FS_ENTRY` returns a slot-local copy of the 32-byte entry so
apps can inspect name, attribute, cluster, and size fields without receiving a
direct writable kernel pointer. Mutating syscalls such as `SYS_FS_DELETE` and
`SYS_FS_RENAME` translate that slot-local handle back to the matching
`FAT16_ROOT_CACHE` offset before changing disk metadata.

### Usermode filesystem kit

Owner:
- `src/user/lib/grit_fs.inc`

The user library defines:

| Symbol | Meaning |
|---|---|
| `NFS_NAME_LEN` | FAT 8.3 syscall name length, always 11 bytes |
| `NFS_ENTRY_SIZE` | FAT16 directory entry length, always 32 bytes |
| `NFS_ATTR_OFF` | Attribute byte offset |
| `NFS_CLUSTER_OFF` | First-cluster low word offset |
| `NFS_SIZE_OFF` | File-size dword offset |
| `NFS_NAME83 dst, src` | Macro wrapper around `nfs_name83` |
| `nfs_name83` | Converts `NAME.EXT` strings to uppercase, space-padded 8.3 names |

## Input Event Structs

Defined in `structs.inc`:

### `key_event_t`

| Field | Meaning |
|---|---|
| `scancode` | raw scancode |
| `ascii` | translated ASCII byte |
| `modifiers` | `KMOD_*` flags |
| `pressed` | press/release state |

### `mouse_event_t`

| Field | Meaning |
|---|---|
| `x` | cursor X |
| `y` | cursor Y |
| `buttons` | current button bitmask |
| `event_type` | `MEVT_*` |

## E820 Entry Layout

Defined in `structs.inc` as `e820_entry_t`:

| Field | Meaning |
|---|---|
| `base` | region base |
| `length` | region length |
| `type` | usable/reserved/ACPI etc. |
| `acpi` | ACPI extended attributes |
