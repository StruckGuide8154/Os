# Grit Syscall ABI

This is the current ring-3 syscall surface exported by
`C:\Users\user\Documents\new\src\kernel\proc\syscall.asm` and wrapped by
`C:\Users\user\Documents\new\src\include\syscall_user.inc`.
Validation helpers live in
`C:\Users\user\Documents\new\src\kernel\proc\syscall_validation.inc`.

## Calling convention

Use the x86-64 `syscall` instruction.

- `RAX`: syscall number
- `RDI`: arg0
- `RSI`: arg1
- `RDX`: arg2
- `R10`: arg3
- `R8`: arg4
- `R9`: arg5
- Return value: `RAX` when the syscall returns one

User apps should normally call the wrapper macros from
`C:\Users\user\Documents\new\src\include\syscall_user.inc` or the convenience
include `C:\Users\user\Documents\new\src\user\lib\grit_app.inc`.

For the built-in apps and future external apps, the kernel now treats these
address classes differently:

- App slot arena: `APP_DATA_ADDR + slot * APP_SLOT_SIZE`
- Built-in user blob: `app_blob_start .. app_blob_end`
- Shared media scratch buffers used by the current built-ins:
  `APP_BMP_FILE_BUF` and `APP_PAINT_CANVAS_BUF`

Rejected pointer-bearing syscalls now return `-1` in `RAX`.

## Syscall table

`0` `SYS_PRINT`
- Args: `RDI = pointer to NUL-terminated string`
- Effect: print debug text
- Returns: `0` on success, `-1` on validation failure
- Validation: string must live in the app slot arena or built-in user blob

`1` `SYS_EXIT`
- Args: none
- Effect: return from usermode
- Returns: `0`

`2` `SYS_GUI_RECT`
- Args: `RDI=x`, `RSI=y`, `RDX=w`, `R10=h`, `R8=color`
- Effect: draw rectangle
- Returns: `0`

`3` `SYS_GUI_TEXT`
- Args: `RDI=x`, `RSI=y`, `RDX=string_ptr`, `R10=color`, `R8=scale_or_flags`
- Effect: draw text
- Returns: `0` on success, `-1` on validation failure
- Validation: string must live in the app slot arena or built-in user blob

`4` `SYS_FS_COUNT`
- Args: none
- Returns: file count in `RAX`

`5` `SYS_FS_ENTRY`
- Args: `RDI=index`
- Returns: opaque FAT16 entry handle in `RAX`

`6` `SYS_FS_CHDIR`
- Args: `RDI=directory_cluster_or_handle`
- Effect: change current directory
- Returns: filesystem result in `RAX`

`7` `SYS_WM_CREATE`
- Args: `RDI=x`, `RSI=y`, `RDX=w`, `R10=h`, `R8=title_ptr`, `R9=draw_handler`
- Returns: window id in `RAX`
- Validation: title must be an app-owned string; draw handler must be null or
  an app-owned code pointer

`8` `SYS_FS_READ`
- Args: `RDI=entry`, `RSI=buffer`, `RDX=buffer_size`
- Returns: bytes read in `RAX`
- Validation: `RDI` must be an opaque FAT16 entry handle from `SYS_FS_ENTRY`;
  destination buffer must live in app-owned memory or the shared media buffers

`9` `SYS_WM_HANDLERS`
- Args: `RDI=window_id`, `RSI=click_handler`, `RDX=key_handler`
- Returns: `0` on success, `-1` on validation failure
- Security rules:
- the kernel rejects `window_id >= MAX_WINDOWS` with an unsigned bounds check
- the kernel only accepts handler installs on active windows
- handler pointers must be null or app-owned code pointers

`10` `SYS_APP_DONE`
- Args: none
- Effect: explicit return path from ring-3 app trampoline

`11` `SYS_FS_FORMAT_NAME`
- Args: `RDI=src_ptr`, `RSI=dst_ptr`
- Effect: format a FAT16 name
- Returns: `0` on success, `-1` on validation failure
- Validation: source must be an opaque FAT16 entry handle; destination must be
  an app-owned writable buffer

`12` `SYS_APP_LAUNCH`
- Args: `RDI=entry_or_app_id`
- Returns: launcher-specific result in `RAX`

`13` `SYS_FS_WRITE`
- Args: `RDI=entry`, `RSI=buffer`, `RDX=buffer_size`
- Returns: bytes written in `RAX`
- Validation: filename buffer must be an app-owned 11-byte FAT16 name; source
  buffer must live in app-owned memory or the shared media buffers

`14` `SYS_FS_SYNC_ROOT`
- Args: none
- Effect: flush FAT16 root state
- Returns: `0`

`15` `SYS_WM_CLOSE`
- Args: `RDI=window_id`
- Security rule: the kernel uses an unsigned bounds check, so negative ids do
  not underflow into the window pool
- Returns: `0`

`16` `SYS_DISPLAY_SET_MODE`
- Args: `RDI=width`, `RSI=height`, `RDX=bpp_or_mode`
- Returns: mode-switch result in `RAX`
- Validation: width and height must be non-zero 32-bit values, bpp must be 32,
  and the requested pixel count must fit the boot back buffer.

`17` `SYS_CURSOR_INIT`
- Args: none
- Effect: initialize cursor state
- Returns: `0`

`18` `SYS_TICKS`
- Args: none
- Effect: read the kernel PIT tick counter
- Returns: current tick count in `RAX`
- Intended use: UI animation such as GritHL blinking carets

`19` `SYS_FS_DELETE`
- Args: `RDI=entry`
- Effect: delete a file or empty directory from the current FAT16 directory
- Returns: `0` on success, `-1` on validation failure, non-empty directory, or
  invalid entry
- Validation: `entry` must be an opaque FAT16 handle from `SYS_FS_ENTRY`

`20` `SYS_FS_RENAME`
- Args: `RDI=entry`, `RSI=name83_ptr`
- Effect: rename an entry in the current FAT16 directory
- Returns: `0` on success, `-1` on validation failure or duplicate name
- Validation: `entry` must be an opaque FAT16 handle; `name83_ptr` must point
  to an 11-byte, space-padded FAT 8.3 name in app-owned memory

`21` `SYS_FS_MKDIR`
- Args: `RDI=name83_ptr`
- Effect: create a real single-cluster FAT16 directory in the current directory
- Returns: `0` on success, `-1` on validation failure, duplicate name, full
  directory, or full FAT
- Validation: `name83_ptr` must point to an 11-byte, space-padded FAT 8.3 name
  in app-owned memory

`22` `SYS_OPEN_FILE_NP`
- Args: `RDI=entry`
- Effect: launch Notepad and load the selected file
- Returns: Notepad window id in `RAX`, or `-1`
- Validation: `entry` must be an opaque FAT16 handle from `SYS_FS_ENTRY`

`23` `SYS_APP_OPEN`
- Args: `RDI=command_line_ptr`
- Effect: launch an app from a command string of the form `"<app> <params>"`
  (e.g. `notepad README.TXT`, `ping 8.8.8.8`). The first whitespace/comma
  separates the app name from the param tail; the tail is copied (up to 255
  bytes) into the new window's L3 slot at `APP_SLOT_PARAM_OFF` (`0x17C000`)
  for the launched app to read. Notepad treats the param as a FAT16 path and
  loads it; other apps receive the raw string.
- Returns: launched window id in `RAX`, or `-1`
- Validation: command line must be an app-owned NUL-terminated string; app
  name must match the registry in `app_command_name_to_id` (case-insensitive)
- See: `docs/app-authoring.md` § Launching apps with parameters

`24` `SYS_DISPLAY_FLAGS`
- Args: none
- Effect: read display option bits
- Returns: flags in `RAX`; bit 0 is VSync, bit 1 is the FPS overlay
- Intended use: Settings and other UI apps that need to reflect current display
  toggles without reading kernel globals

`25` `SYS_DISPLAY_SET_FLAGS`
- Args: `RDI=flags`
- Effect: update display option bits; bit 0 controls VSync, bit 1 controls the
  FPS overlay
- Returns: `0` on success, `-1` on validation failure
- Validation: flags must fit in the low 32 bits; unknown high bits are ignored

`26` `SYS_DESKTOP_BG`
- Args: none
- Effect: read the active desktop background theme id
- Returns: `0` Liquid Metal, `1` Glass Ribbons, or `2` Frosted Bloom

`27` `SYS_DESKTOP_SET_BG`
- Args: `RDI=theme_id`
- Effect: switch the whole desktop wallpaper/background renderer
- Returns: `0` on success, `-1` on validation failure
- Validation: theme id must be `0`, `1`, or `2`

`28` `SYS_DISPLAY_NATIVE`
- Args: none
- Returns: native framebuffer size packed as `width | (height << 32)`

`29` `SYS_DISPLAY_SIZE`
- Args: none
- Returns: current logical desktop size packed as `width | (height << 32)`

`30` `SYS_XML_PARSE`
- Args: `RDI=buffer`, `RSI=len`
- Returns: `1` on parse success, `0` on parse error, `-1` on validation failure
- Validation: XML buffer must live in app-owned readable memory

`31` through `39` `SYS_XML_*`
- `31` root, `32` tag id, `33` tag name copy, `34` first child,
  `35` next sibling, `36` parent, `37` attribute copy, `38` text copy,
  `39` free current document
- Pointer outputs are validated as app-owned writable ranges

`40` `SYS_DRAW_LINE`
- Args: `RDI=x0`, `RSI=y0`, `RDX=x1`, `R10=y1`, `R8=color`
- Effect: draw a clipped Bresenham line into the back buffer

`41` `SYS_FILL_CIRCLE`
- Args: `RDI=cx`, `RSI=cy`, `RDX=r`, `R10=color`
- Effect: draw a clipped filled circle into the back buffer

`42` `SYS_FILL_TRIANGLE`
- Args: `RDI=coords_ptr`, `RSI=color`
- Effect: draw a clipped filled triangle from six int32 coords
- Validation: `coords_ptr` must point to a 24-byte app-owned buffer

`43` `SYS_XML_LAST_ERROR`
- Args: none
- Returns: packed parse diagnostic, `error_code | (byte_offset << 32)`

`44` `SYS_XML_NODE_COUNT`
- Args: none
- Returns: node count in the current XML document

`45` `SYS_BLEND_PIXEL`
- Args: `RDI=x`, `RSI=y`, `RDX=argb`
- Effect: source-over blend one ARGB pixel into the back buffer

`46` `SYS_BLEND_SPAN`
- Args: `RDI=x`, `RSI=y`, `RDX=len`, `R10=argb`
- Effect: source-over blend a horizontal ARGB span into the back buffer

`47` `SYS_XML_TEXT_RUNS`
- Args: `RDI=node`
- Returns: mixed-content text run count, `0` for empty content, or `-1` for an
  invalid node

`48` `SYS_XML_TEXT_RUN`
- Args: `RDI=node`, `RSI=run_index`, `RDX=out`, `R10=max`
- Returns: bytes copied from the selected mixed-content text run, or `-1`
- Validation: `out` must point to an app-owned writable buffer

`49` `SYS_XML_NAMESPACE`
- Args: `RDI=node`, `RSI=prefix`, `RDX=prefix_len`, `R10=out`, `R8=max`
- Returns: namespace URI length copied from the nearest `xmlns` binding, or `-1`
- Validation: non-empty `prefix` and `out` must be app-owned buffers

`50` `SYS_XML_NODE_NAMESPACE`
- Args: `RDI=node`, `RSI=out`, `RDX=max`
- Returns: namespace URI length for the node's tag prefix, or `-1`
- Validation: `out` must point to an app-owned writable buffer

`51` `SYS_XML_ENTITY_VALUE`
- Args: `RDI=name`, `RSI=name_len`, `RDX=out`, `R10=max`
- Returns: bytes copied from a custom internal-DTD entity value, or `-1`
- Validation: `name` and `out` must be app-owned buffers

`55` `SYS_SYSINFO`
- Args: `RDI=selector`, `RSI=arg`
- Returns: system information scalar such as FPS, RAM, CPU MHz, core count, or
  per-core utilization. See `src/user/grithl/lib/core.ghl`.
- GPU selectors expose the passive AMD display provider state used by Settings:
  provider/status, BDF, device/vendor ID, class, BAR0 low/high dwords, command
  register, and active flag. These are identity/readiness values only; the
  kernel still does not enable PCI decode or touch AMD MMIO during this phase.

`56` `SYS_NET_PING4`
- Args: `RDI=IPv4 address packed as A.B.C.D`, for example `8.8.8.8` is
  `0x08080808`
- Returns: approximate ICMP echo RTT in milliseconds, or `-1` after a 2 second
  timeout or network failure
- Scope: system-wide kernel network service. Apps should call the GritHL
  wrapper in `src/user/grithl/lib/net.ghl` instead of issuing the syscall
  directly.

`57` `SYS_NET_INFO`
- Args: `RDI=selector`
- Returns: current network state scalar. Selector `9` returns the DHCP-learned
  DNS server in A.B.C.D order, falling back to the DHCP server identifier when
  no DNS option was provided.
- Scope: diagnostic/app status surface. Apps should use `net_info()` and the
  `NI_*` constants in `src/user/grithl/lib/core.ghl`.

`60` `SYS_NET_TCP_CONNECT4`
- Args: `RDI=IPv4 address packed as A.B.C.D`, `RSI=destination port`,
  `RDX=source port`
- Returns: `1` if the TCP SYN was queued/sent, `0` on network failure, `-1`
  for invalid arguments, or `-2` if another TCP open is in flight
- Scope: generic kernel TCP path. It resolves the current next-hop with ARP,
  builds IPv4/TCP above the selected NIC, and does not call NIC-specific TCP
  code.

`61` `SYS_NET_DNS_A`
- Args: `RDI=app-owned hostname C-string`
- Returns: IPv4 address packed as A.B.C.D, `0` when lookup fails, `-1` for an
  invalid pointer/name, or `-2` if another DNS lookup is in flight
- Scope: generic kernel DNS path. It uses the DHCP-learned DNS server exposed
  by `SYS_NET_INFO` selector `9`, sends a UDP query through `net/udp.asm`, and
  currently returns the first A record in the response.

## Current hardening notes

- Syscall 9 no longer accepts out-of-range window ids and no longer installs
  handlers on inactive slots.
- Pointer-taking syscalls validate app-owned strings, buffers, callback
  pointers, and opaque FAT16 handles before calling kernel helpers.
- Mutating filesystem syscalls translate slot-local opaque entry copies back to
  the kernel's current-directory cache before writing metadata.
- Window close uses unsigned validation for the same reason.
- The usermode callback return path depends on the runtime layout in
  `src/kernel/proc/usermode.asm`; if `L3_RT_SIZE` changes, keep the allocation
  in sync.

## Authoring rules for user apps

- Keep callback code under `src/user`.
- Include `grit_app.inc` for the stable wrapper surface.
- Include `grit_window.inc` when app code needs window offsets or app ids.
- Treat every kernel-facing pointer as privileged: only pass app-owned buffers
  and app-owned strings.
- Treat FAT16 entry pointers as opaque handles. They are kernel objects, not
  user-owned memory.
- Use `src/user/lib/grit_fs.inc` helpers such as `NFS_NAME83` when converting
  user-visible filenames to the 11-byte FAT 8.3 names accepted by write,
  rename, and mkdir.
- Return from callbacks with `ret` unless you intentionally end the callback
  via `SYS_APP_DONE`.
