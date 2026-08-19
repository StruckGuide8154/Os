# FAT16 -> VFS Migration Audit

Status: pre-runtime VFS foundation. This is the concrete blocker list discovered while reviewing `src/kernel/grithlk/fat16_core.ghl` before adapting it as VFS backend #1.

The migration rule is strict: **the VFS adapter must not merely wrap legacy behavior**. Existing semantics that can hide I/O failure, retain unstable cache identity, or create partially-mutated metadata are fixed or explicitly translated before a VFS syscall is allowed to depend on them.

## P0: authority and identity

### 1. Directory cache pointers are not object identity

`fat16_get_entry()` returns a pointer into `fat16_root_cache`. That cache is reloaded for different directories and different app-slot cwd ownership, so the pointer is only a transient view.

**VFS rule:** no `fat16_root_cache` pointer may be stored in `VfsNode`, `VfsFile`, a user-visible handle, a dentry, or a long-lived backend object.

**Replacement:** `vfs_fat16_key.ghl` identifies an entry by `(parent directory cluster, raw directory slot)`. The VFS node generation + explicit STALE state prevents delete/recreate ABA reuse. Root uses a separate typed key.

### 2. Shared live cwd/cache must not become VFS namespace state

FAT16 currently switches one live directory cache between app slots using `fat16_cache_owner` and per-slot cwd clusters. That is compatibility state, not a scalable namespace model.

**VFS rule:** cwd/root are per-app VFS directory capabilities. Path/object identity must not depend on which slot most recently materialized the FAT cache.

**Migration:** the FAT backend may temporarily materialize a requested directory into bounded backend scratch under its own lock, but generic VFS state remains independent of the shared cache.

## P0: hidden write failures

### 3. `fat16_flush_fats()` discards ATA write failures

Both FAT copies are written without checking/propagating `ata_write_sectors()` return values, and the function returns success unconditionally.

**Required fix:** every FAT write is checked. Failure returns a stable backend error and marks the volume dirty/error-state. The second FAT copy is not reported successful if either required copy failed.

### 4. `fat16_flush_current_dir()` discards ATA write failures

Root and subdirectory writes call `ata_write_sectors()` but return success unless geometry/LBA setup failed.

**Required fix:** propagate the device result. VFS metadata mutation cannot return success before the directory write is known to have reached the block layer.

### 5. mutators ignore flush outcomes

Delete, rename, mkdir and write paths call FAT/directory flush helpers but do not consistently gate their own success on those results.

**Required fix:** no mutating operation returns success if a required metadata write/flush failed. Before journaling lands, failure transitions the mount to an explicit error/read-only state where continued mutation could compound corruption.

## P0: partial-directory trust

### 6. subdirectory reload can return success after a partial/failed chain walk

`f16_change_dir_load()` clears the cache, walks the cluster chain, and `break`s on invalid cluster/LBA, cache extent exhaustion, or ATA read failure. It then checks the canary/count and returns success.

That can make a partially-read directory look like a complete trusted directory.

**Required fix:** distinguish clean EOC from failure/truncation. Any unexpected chain termination, read failure, or directory larger than the supported materialization bound fails closed. The old cache must not become authoritative.

### 7. `fat16_switch_to()` claims cache ownership even if reload failed

The caller reloads a slot cwd but does not gate the subsequent owner assignment on the reload result.

**Required fix:** only publish `fat16_cache_owner = slot` after a complete successful materialization. On failure owner remains NONE and the caller receives an error.

## P0/P1: mutation atomicity

### 8. overwrite destroys the old chain before the replacement is committed

For an existing file, `fat16_write_file()` frees the old cluster chain and rewrites directory metadata before proving the replacement allocation and data writes can complete.

A mid-write failure can therefore destroy the old version and leave a partially-linked replacement.

**Required transition:**

1. preflight capacity or build a replacement chain without modifying the old chain;
2. write replacement data;
3. transactionally switch directory metadata;
4. only then reclaim the old chain.

The final design performs this through the fixed metadata journal described in `vfs-architecture.md`.

### 9. free-cluster search does not wrap

`f16_find_free_cluster(start)` scans only from `start` to the FAT end. Sequential allocation therefore can report no space even when reusable clusters exist below `start`.

**Required fix:** bounded two-range search (`start..end`, then `2..start-1`) or a bounded free-space cursor/bitmap. Never loop without a geometry-derived maximum.

## P1: read semantics

### 10. midstream read failure currently looks like a short successful read

`fat16_read_file()` returns `got` when cluster validation or ATA read fails after some bytes were copied. A caller cannot distinguish EOF/short destination from media corruption/I/O failure.

**VFS contract:** `pread/read` must have an explicit partial-I/O policy. For VFS v1, backend read returns both transferred byte count and status internally; a hard metadata/device failure is never silently reclassified as EOF. The syscall layer can then apply a documented short-read rule.

### 11. current read API starts at byte zero

VFS needs `pread`/open-file offset semantics. Re-reading from byte zero and discarding a prefix would be both slow and attackable for large files.

**Required backend primitive:** `fat16_vfs_read_at(key, offset, dst, len)` skips complete clusters with bounded traversal, validates the target chain, and copies only the requested range. A later `VfsFile` cursor may cache the last cluster for sequential reads after correctness is proven.

## P1: geometry hardening

The current BPB parser already checks the 512-byte sector size, nonzero bounded sectors-per-cluster, FAT count, root extent, FAT cache size, total sectors, and basic root/data placement. Before VFS mount accepts the volume, also prove:

- sectors/cluster is a FAT-valid power of two;
- `0xFFF7` is rejected as the FAT16 BAD-cluster marker (the legacy `< 0xFFF8` style checks currently admit it as if it were data); valid ordinary data clusters stop at `0xFFF6`;
- every `reserved + fats * fat_size + root_sectors` arithmetic step is overflow-safe;
- FAT capacity in entries is sufficient for the computed data-cluster geometry;
- all FAT/root/data regions are monotonic and inside the partition/device extent;
- partition base + relative LBA cannot overflow the block-device extent;
- FAT16 cluster-count classification is actually FAT16, not FAT12/FAT32-shaped media being forced through this parser.

## P1: concurrency boundary

The current FAT implementation owns one mutable live directory cache and shared staging buffers. Until the backend is refactored, VFS must serialize **backend cache materialization/mutation**, but must not impose a global VFS lock on unrelated generic object reads.

The migration sequence is:

1. keep VFS node/file/capability state outside FAT scratch;
2. add a bounded FAT backend lock for current shared scratch;
3. implement key-based lookup/read primitives;
4. move toward per-operation/per-directory scratch or immutable cached metadata;
5. only then enable parallel physical-backend reads where buffers no longer alias.

## Exit gate for read-only VFS

The first runtime read-only VFS path may land only when all of the following hold:

- no VFS object retains a FAT cache pointer;
- key -> entry materialization validates key kind, parent cluster and raw slot;
- directory materialization fails on partial reads/corrupt chains;
- `read_at` is offset-aware and bounded;
- backend errors map to stable VFS errors rather than blanket `-1`/short-success ambiguity;
- app A and app B cannot alter each other's cwd by shared FAT cache state;
- random/stale/cross-slot VFS handles fail before the FAT backend is entered;
- the VFS object and FAT key contract CI remains green.

## Exit gate for writable VFS

Writable exposure additionally requires:

- all ATA metadata write results propagated;
- no destructive overwrite-before-commit path;
- bounded wraparound allocation;
- explicit mount error/read-only demotion on uncertain metadata state;
- journal/recovery implementation and crash-injection tests;
- consistency checker clean after every injected persistence boundary.
