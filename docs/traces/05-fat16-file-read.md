# Trace 05 - User App `SYS_FS_READ(handle, buf, len)` → Disk Sector

## Entry

User app executes `syscall` with rax=4 (SYS_FS_READ), rdi=handle (FAT16 dir-entry pointer), rsi=user buffer, rdx=byte count.

## Step-by-step

| # | File:Line | Action |
|---|---|---|
| 1 | `kernel/proc/syscall.asm` syscall entry | swapgs not used; saves user GPRs onto kernel stack frame `[rsp + ALL_*]` |
| 2 | syscall.asm | `cmp eax, 4 / je .sc_fs_read` |
| 3 | syscall.asm:454-458 | `call sc_validate_dir_entry_handle` - validates rdi is in FAT16_ROOT_CACHE or L3 dir-cache range |
| 4 | syscall.asm:459-463 | `mov rdi, rsi; mov rsi, rdx; call sc_validate_user_io_range` - checks buf+len in user arena |
| 5 | syscall.asm:464-467 | restore rdi/rsi/rdx from saved frame |
| 6 | syscall.asm:467 | `call fat16_read_file(rdi=entry, rsi=buf, edx=maxbytes)` |

## fat16_read_file internals (`kernel/fs/fat16.asm`)

| # | Action |
|---|---|
| a | First cluster from entry+26 (LO) + entry+20 (HI for FAT32, ignored for FAT16) |
| b | File size from entry+28 (dword) - clamp `bytes_to_read = min(maxbytes, size)` |
| c | While bytes left and cluster ∈ [2, 0xFFEF]: |
|   |   • LBA = `FAT16_DATA_LBA + (cluster - 2) * sectors_per_cluster` |
|   |   • For each sector in cluster: `call ata_read_sectors(rdi=lba, rsi=tmp_sec, edx=1)` |
|   |   • memcpy from tmp_sec to user buf, advance ptr/count |
|   |   • Next cluster = `[FAT16_FAT_CACHE + cluster*2]` (word) |
| d | Returns EAX = bytes read |

## ata_read_sectors (`kernel/drivers/ata.asm`)

| # | File:Line | Action |
|---|---|---|
| i | ata.asm:59 | `call ata_select_drive` - writes drive register, IO wait, then `ata_wait_ready` |
| ii | ata.asm:64-83 | sector count=1; LBA bytes 0/8/16 to ports 0x1F2/3/4/5 |
| iii | ata.asm:85-88 | command 0x20 (READ) to 0x1F7 |
| iv | ata.asm:91 | `call ata_wait_drq` - PIT-deadline 100 ticks (Round 9) |
| v | ata.asm:96-99 | `mov dx, 0x1F0; mov ecx, 256; rep insw` - 512 bytes |
| vi | loop next sector |

## Audit-pass changes

- **Round 9**: `ata_wait_ready` and `ata_wait_drq` were CPU-spin (1M iter, QEMU-calibrated). Now PIT-tick deadline. Added `extern tick_count`. `push rbx`/`pop rbx` scopes deadline register.
- **Round 8**: `sc_validate_dir_entry_handle` (syscall_validation.inc:99) verified to accept pointers into FAT16_ROOT_CACHE OR L3 app dir-entry-cache only - neither overlaps with kernel writable structures, so the handle can't be used as kernel write primitive.

## Failure modes

- Bad handle → -1 returned, no read.
- Bad user buffer → -1 returned, no read.
- ATA timeout → fat16_read_file returns whatever was read so far (or 0).
- Cluster chain corrupt (cluster < 2 or >= 0xFFF8) → loop terminates early.

## Invariants

- handle is a 32-byte-aligned pointer into a validated dir-entry cache.
- user buf+len lies entirely in the calling app's L3 arena.
- bytes-returned ≤ min(maxbytes, file size).
- after read, file position is not persisted (no seek state in this kernel - each read starts at offset 0).
