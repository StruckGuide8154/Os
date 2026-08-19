# Grit Virtual File System Architecture

Status: **Phase 1 foundation**. This document is the implementation contract for the VFS migration. FAT16 remains the active backend until the migration gates below pass.

## Goals

The VFS must be simultaneously small enough to audit, fast enough that abstraction overhead is lost in measurement noise, and strict enough that malformed media or a compromised app cannot turn filesystem metadata into ambient kernel authority.

The target hot read path is:

```text
ring 3 -> syscall snapshot/range validation -> O(1) capability handle
       -> VfsFile -> VfsNode -> backend read -> RAM image/block cache
       -> one required copy to/from user memory
```

After `open`, normal reads perform **no pathname parsing, directory scan, allocation, crypto, or global VFS locking**.

## Non-negotiable invariants

1. No FAT16 directory-entry pointer or other backend object crosses ring 0.
2. No raw kernel pointer crosses ring 0.
3. No user pointer reaches a filesystem backend. Syscall arguments are validated and request/path structures are snapshotted first.
4. Every open object is represented by a slot-local capability handle with immutable rights.
5. Child capabilities can only lose rights. Rights are `parent & requested & mount-policy`.
6. Path authority becomes object authority after `open`; reads and writes do not re-resolve names.
7. All offset, size, sector and cluster arithmetic is checked before the dangerous add/multiply or I/O.
8. Disk-controlled loops are bounded by geometry-derived maxima.
9. Normal reads take no global VFS lock.
10. A cached open read performs no allocation, crypto, path work or directory scan.

`src/kernel/grithlk/vfs_core.ghl` owns the small pure policy kernel for rights, mount restrictions, flags, stable errors and checked arithmetic. It deliberately declares no unsafe capability.

## Object model

The implementation converges on six generic objects:

```text
VfsHandle  -> slot-local capability: object id/generation/type/rights
VfsFile    -> one open instance: node, offset, flags, rights, refs
VfsNode    -> backend-independent identity: super, backend id, type, size, generation
VfsDentry  -> cached (parent, canonical name) -> node relationship
VfsMount   -> namespace attachment + immutable mount flags
VfsSuper   -> mounted filesystem instance + backend ops + block device
```

Only `backend_private`/backend ids may contain FAT16-specific state. FAT16 state must not leak into syscall ABI or generic cache keys.

## Capability rights

VFS v1 defines separate rights for lookup, read, write, stat, enumeration, creation, mkdir, delete, rename source, rename destination, traversal and sync. There is intentionally no root/admin/bypass right.

Applications should normally receive pre-opened directory capabilities such as a private home directory. `openat(dir_cap, relative_path, ...)` is the primary pathname operation. A path resolver may never climb above the supplied capability root.

## Path rules

There is exactly one VFS path parser. VFS v1 uses `/`, rejects embedded NUL, bounds the full path to 1024 bytes and each component to 255 bytes, resolves `.` structurally, and handles `..` without string concatenation. At a capability root, `..` cannot escape the root.

Symlinks and hard links are intentionally out of VFS v1. When symlinks are introduced later, the resolver must have an explicit traversal bound plus BENEATH/NO_SYMLINK/NO_XDEV policy modes.

## Syscall migration

The backend-neutral target surface is:

```text
VFS_OPENAT, VFS_CLOSE
VFS_READ, VFS_WRITE, VFS_PREAD, VFS_PWRITE, VFS_SEEK
VFS_FSTAT, VFS_READDIR
VFS_MKDIRAT, VFS_UNLINKAT, VFS_RENAMEAT
VFS_FSYNC
```

Complex calls use fixed-size request structures. The syscall layer validates the entire user range, copies the request and pathname into kernel-owned memory, and never consults the original request again. This is mandatory TOCTOU protection.

Existing `SYS_FS_*` numbers may remain temporarily as compatibility wrappers, but they must eventually translate only to VFS operations. No compatibility wrapper may expose a FAT16 entry pointer.

## FAT16 backend

The existing GritHLK FAT16 driver becomes backend #1. Its final interface is limited to mount/lookup/getattr/open/close/read/write/readdir/create/mkdir/unlink/rename/sync. Backends receive only kernel-owned objects, validated component data and validated kernel buffers.

Mount parsing treats the image as hostile. BPB geometry, FAT extents, root extents, cluster counts and every derived LBA are validated. Cluster-chain traversal is bounded by the number of valid clusters. File size and chain capacity must agree or the operation fails with `VFS_EIO`.

Repeated structural corruption can demote a writable mount to read-only rather than allowing further metadata mutation.

## Block layer and caching

FAT16 must not know whether storage is ATA or the RAM-backed `DATA.IMG`. A later `BlockDevice` layer exposes read/write/flush plus sector size/count and immutable traits.

Caching is media-aware:

- RAM-backed image: dentry/node/metadata caches are useful; duplicating file data into a second page cache is not.
- Physical ATA: use a bounded 4 KiB page/block cache with sector-valid and dirty bits, plus adaptive sequential read-ahead.

All caches have hard capacity limits and reclaim. Negative dentries are keyed with a per-boot keyed hash and have stricter quotas so random-name misses cannot become a kernel-memory DoS.

## SMP/locking

There is no single VFS-wide lock. The target ordering is namespace -> superblock -> node/directory -> open-file offset -> cache bucket/page -> backend metadata transaction. Debug verification must detect ordering violations where practical.

FAT allocation/metadata mutation may serialize per volume, but independent cached reads must progress concurrently.

## Durability

Native FAT16 metadata updates are not sufficient for a high-assurance writable filesystem. The target backend reserves a fixed-size `GRITJNL.SYS` metadata journal created at format time. Create/mkdir/delete/rename/allocation/extension/truncate are transactions with checksummed intent, ordered flushes and deterministic recovery.

`fsync` must only claim durability that the block device can actually provide.

## Performance gates

A VFS implementation is not considered performance-complete until:

- opened cached read: 0 allocations, 0 path lookups, 0 crypto, 0 global VFS lock;
- handle lookup: O(1);
- hot dentry lookup: expected O(1);
- VFS overhead on cached reads: <3%;
- hot-open overhead against equivalent direct cached lookup: <5%;
- physical sequential throughput: >=95% of raw block-layer throughput;
- RAM-image sequential throughput: >=97% of the direct validated-copy baseline;
- user/kernel transfer uses only the directionally necessary copy.

QEMU numbers are regression gates; real hardware numbers decide performance claims.

## Security gates

Before legacy FAT-facing ABI removal, tests must prove rejection of random/cross-slot/stale/wrong-type handles, rights amplification, traversal escape, unknown flags, range overflow, malformed BPBs, FAT cycles, invalid clusters/LBAs, oversized names, cache flooding, non-empty directory deletion, rename collisions and writable-file execution without independent loader authorization.

Filesystem fuzzing must terminate in success or an explicit error, never a hang, panic, out-of-bounds access or I/O outside the device extent.

Crash injection must test every metadata persistence boundary. After reboot, a transaction is either wholly old or wholly new; the consistency checker must never observe a half-state.

## Implementation sequence

1. **Policy core**: zero-unsafe GritHLK `vfs_core.ghl`, stable rights/errors/flags/arithmetic. (current phase)
2. **Compile/security gate**: standalone test proves the module compiles `--forbid-asm` with zero declared unsafe capabilities.
3. **Backend contract**: expose generic FAT16 lookup/read/stat/readdir primitives without changing the public syscall behaviour.
4. **Handle/file/node core**: generation-safe slot-local VFS handles and bounded object pools.
5. **Read-only VFS**: mount/root/openat/read/pread/stat/readdir/close on FAT16.
6. **Syscall bridge**: snapshot request structs and migrate Explorer/Notepad behind compatibility wrappers.
7. **Mutation**: write/create/mkdir/unlink/rename/fsync with explicit stable errors.
8. **Journal/recovery**: transactional metadata + crash injection.
9. **Caches/perf**: dentry/node/block/read-ahead, each independently security-gated.
10. **SMP hardening**: final lock hierarchy and 1/2/4/8-core stress.
11. **Legacy removal**: delete userspace FAT16 entry semantics and global/shared cwd assumptions.
12. **Measured optimisation**: only profile-proven hot spots are optimized.

## Explicitly deferred

VFS v1 does not implement symlinks, hard links, mmap, network filesystems, FUSE-like filesystems, ACLs, extended attributes, snapshots, async I/O, device special files or dynamic mount namespaces. The object model leaves room for them without paying their attack-surface or complexity cost today.
