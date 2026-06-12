# GritOS Resource Formats

Three custom file formats for icons, fonts, and palettes. All three are:

- **Memory-mappable.** Load file into a buffer; the bytes ARE the structure.
- **Little-endian.** x86-64 native, no byte swapping.
- **Naturally aligned.** Multi-byte fields land on their own boundary.
- **Header + payload.** Fixed-size header so you can `mov`/`movzx` fields by offset; payload follows immediately.
- **No allocation, no decompression.** All formats are uncompressed and parsed in zero passes.

Magic strings are 4 ASCII chars stored little-endian. A 4-byte `dword` compare is the fastest sanity check.

```nasm
NPL1_MAGIC  equ 0x314C504E   ; "NPL1"
NIC1_MAGIC  equ 0x3143494E   ; "NIC1"
NFT1_MAGIC  equ 0x3154464E   ; "NFT1"
```

---

## 1. `.npl` - Grit Palette

Theme color tokens. Used for **chrome** (window backgrounds, borders, text, accents) - NOT for icons. Icons store full color directly.

### File layout

```
Offset  Size  Field
------  ----  --------------------------------------
0       4     magic = "NPL1"
4       2     count       (uint16)
6       1     channels    (uint8, 3 = RGB, 4 = RGBA)
7       1     reserved    (0)
8       N*ch  entries     (count * channels bytes)
```

### Standard themes

| File                    | Count | Channels | Size  | Purpose          |
|-------------------------|-------|----------|-------|------------------|
| `palette_light.npl`     | 16    | 3 (RGB)  | 56 B  | Default light    |
| `palette_dark.npl`      | 16    | 3 (RGB)  | 56 B  | Dark mode        |

### Semantic indices (both palettes use the same slot layout)

| Idx | Name          | Light         | Dark          | Usage                          |
|-----|---------------|---------------|---------------|--------------------------------|
| 0   | bg-base       | `#F5F6FA`     | `#10121A`     | Desktop, taskbar background    |
| 1   | surface       | `#FFFFFF`     | `#1A1D26`     | Window body                    |
| 2   | surface-2     | `#ECEFF4`     | `#24283 3`    | Sunken regions, hover          |
| 3   | border        | `#D8DDE3`     | `#33394 6`    | 1px hairlines                  |
| 4   | border-strong | `#C4CBD3`     | `#444C5 C`    | Emphasized borders             |
| 5   | text-primary  | `#0F141E`     | `#F0F2F7`     | Body & headings                |
| 6   | text-secondary| `#4B5563`     | `#B4BCCB`     | Subtitles, meta                |
| 7   | text-tertiary | `#8A939F`     | `#768091`     | Placeholders, disabled         |
| 8   | accent-light  | `#4C8BFF`     | `#6BA1FF`     | Gradient top, hover            |
| 9   | accent        | `#2A6FFF`     | `#4C8BFF`     | Buttons, links, focus ring     |
| 10  | accent-dark   | `#1A55D6`     | `#2A6FFF`     | Gradient bottom, pressed       |
| 11  | cyan          | `#36C0E0`     | `#4CD6F5`     | Secondary accent               |
| 12  | cyan-dark     | `#1291B0`     | `#24A9C8`     | Secondary gradient bottom      |
| 13  | error         | `#E5474D`     | `#F2666C`     | Close button, error states     |
| 14  | warning       | `#F7B52C`     | `#FFC14D`     | Battery low, warnings          |
| 15  | success       | `#2EB56E`     | `#4BCE86`     | Battery ok, confirmation       |

### Gradients

Two-stop linear gradients are computed at runtime by interpolating between adjacent palette indices. The combinations the chrome uses:

| Gradient name         | From idx | To idx |
|-----------------------|----------|--------|
| `gradient-accent`     | 8        | 10     |
| `gradient-cyan`       | 11       | 12     |
| `gradient-titlebar`   | 8        | 9      |
| `gradient-surface`    | 1        | 2      |
| `gradient-error`      | 13       | 13     |

To draw a vertical N-row gradient between two RGB triples `a` and `b`:

```nasm
; per row y, interpolate t = y / (height-1) (use fixed-point Q8.8 or similar)
; out_r = a.r + ((b.r - a.r) * y) / (h - 1)
; out_g = a.g + ((b.g - a.g) * y) / (h - 1)
; out_b = a.b + ((b.b - a.b) * y) / (h - 1)
; pack as BGRA, fillrect at row y with this color
```

A LUT of pre-interpolated rows (one per common chrome height) eliminates the division.

### Asm usage

```nasm
; rsi = palette file buffer
cmp     dword [rsi], NPL1_MAGIC
jne     .bad
movzx   ecx, word [rsi+4]      ; color count
movzx   eax, byte [rsi+6]      ; channels per color
lea     rdi, [rsi+8]           ; rdi -> RGB triples
; rdi[idx*3 + 0] = R, +1 = G, +2 = B
```

---

## 2. `.nic` - Grit Icon

True-color icon, optionally indexed. **Default and recommended: bpp=32** (BGRA, 4 bytes per pixel) - gives you alpha, gradients, AA, and is the fastest to blit onto a 32-bit framebuffer (one `mov` per pixel).

### File layout

```
Offset  Size  Field
------  ----  ----------------------------------------------------
0       4     magic = "NIC1"
4       2     width       (uint16, pixels)
6       2     height      (uint16, pixels)
8       1     bpp         (uint8, 4 / 8 / 32)
9       1     flags       (uint8; bit 0 = color 0 transparent, only for bpp<32)
10      2     reserved    (0)
12      4     data_size   (uint32, payload byte count)
16      D     pixel data  (D = data_size bytes)
```

Header = 16 bytes. Payload starts on an 8-byte boundary.

### Pixel encoding by `bpp`

| bpp | Layout                                                       | Row stride                | Use case |
|-----|--------------------------------------------------------------|---------------------------|----------|
| 32  | **BGRA, 4 bytes per pixel.** B, G, R, A in that byte order.  | `width * 4`               | **Default.** Modern shaded icons |
| 8   | One palette index per byte (use with a `.npl`)               | `width`                   | Compact themed icons |
| 4   | Two pixels per byte, high nibble first; uses 16-color palette| `(width + 1) >> 1`        | Legacy / tiny icons |

Rows are stored **top-to-bottom**. Within a row, **left-to-right**. No padding between rows.

### Standard GritOS icon set

| Size    | bpp | Header | Payload | Total | Use case |
|---------|-----|--------|---------|-------|----------|
| 16 x 16 | 32  | 16     | 1,024   | 1,040 | Menu items, tabs, status bar |
| 32 x 32 | 32  | 16     | 4,096   | 4,112 | Window titlebar, taskbar |
| 48 x 48 | 32  | 16     | 9,216   | 9,232 | Dock, desktop, dialog hero |

### Asm blit (bpp=32, with alpha-key)

```nasm
; rsi = icon file, rdi = fb pixel ptr at (dst_x, dst_y), rdx = fb pitch bytes
cmp     dword [rsi], NIC1_MAGIC
jne     .bad
movzx   ecx, word [rsi+4]              ; width
movzx   r9d, word [rsi+6]              ; height
cmp     byte  [rsi+8], 32
jne     .non32                          ; (call indexed path)
lea     rsi, [rsi+16]                  ; src pixels
.row:
    mov     eax, ecx                   ; pixels per row
    mov     r10, rdi
.px:
    mov     ebx, [rsi]                 ; load BGRA dword
    test    ebx, 0xFF000000            ; alpha == 0?
    jz      .skip                      ; fully transparent, leave fb alone
    cmp     ebx, 0xFF000000            ; alpha == 255?
    jae     .opaque                    ; fast path
    ; --- partial alpha branch (optional; omit for binary alpha) ---
    ; call your alpha-blend helper here
    jmp     .step
.opaque:
    mov     [r10], ebx
    jmp     .step
.skip:
.step:
    add     rsi, 4
    add     r10, 4
    dec     eax
    jnz     .px
    add     rdi, rdx                   ; next fb row
    dec     r9d
    jnz     .row
```

For **binary alpha** (the icons in this design system: pixels are either fully opaque or fully transparent), drop the partial-alpha branch entirely. The whole loop becomes `mov ebx, [rsi]; test ebx, 0xFF000000; jz .skip; mov [r10], ebx; .skip:` - about 5 cycles per pixel.

### Asm blit (bpp=4, indexed - legacy)

```nasm
; for each row:
;   for x = 0..width step 2:
;     byte = data[y*stride + x/2]
;     hi = byte >> 4
;     lo = byte & 0x0F
;     if (transparent && hi == 0) skip else plot palette[hi]
;     if (transparent && lo == 0) skip else plot palette[lo]
```

---

## 3. `.nft` - Grit Font

1-bit-per-pixel fixed-size bitmap font, monospaced.

### File layout

```
Offset  Size  Field
------  ----  ---------------------------------------------------
0       4     magic = "NFT1"
4       1     glyph_w        (uint8, pixels)
5       1     glyph_h        (uint8, pixels)
6       2     first_cp       (uint16, first codepoint included)
8       2     glyph_count    (uint16, number of glyphs)
10      2     bytes_per_glyph (uint16)
12      4     reserved       (0)
16      G*bpg glyph_data
```

Header = 16 bytes.

### Glyph encoding

- `bytes_per_glyph = ceil(glyph_w / 8) * glyph_h`.
- For widths ≤ 8: one byte per row, bit 7 = leftmost pixel.
- For widths > 8: each row spans `ceil(w/8)` bytes; bit 7 of byte 0 is the leftmost pixel, bit 7 of byte 1 is the 9th pixel, and so on.
- Rows stored top-to-bottom, contiguous.

### Standard GritOS fonts

All three cover ASCII printable + space (codepoints 32..127, 96 glyphs). Source: JetBrains Mono Bold rasterized at native pixel size.

| File              | W x H   | bytes/glyph | File size | Use case |
|-------------------|---------|-------------|-----------|----------|
| `font_8x16.nft`   | 8 x 16  | 16          | 1,552 B   | Status bars, tiny labels |
| `font_16x32.nft`  | 16 x 32 | 64          | 6,160 B   | **Primary UI.** Window titles, menus, buttons |
| `font_24x48.nft`  | 24 x 48 | 144         | 13,840 B  | Headings, About dialog, splash |

### Lookup

```
if (cp < first_cp || cp >= first_cp + glyph_count) cp = first_cp;
offset = 16 + (cp - first_cp) * bytes_per_glyph;
glyph  = file[offset .. offset + bytes_per_glyph]
```

### Asm draw-char (bpp=32 framebuffer)

```nasm
; al = char, rsi = font file, rdi = fb pixel ptr, rdx = pitch, r9d = fg BGRA
movzx   eax, al
sub     eax, [rsi + 6]                 ; cp - first_cp
movzx   ebx, byte [rsi + 5]            ; glyph_h
movzx   ecx, word [rsi + 10]           ; bytes_per_glyph
imul    eax, ecx
lea     rsi, [rsi + 16 + rax]          ; -> glyph
movzx   r10d, byte [rsi - 12]          ; glyph_w (rsi pre-add+5)
; (in production keep glyph_w in a register before the rebase)
; loop bx rows, glyph_w pixels per row, plot fg where bit==1
```

---

## 4. Loading from FAT16

```nasm
; rdi = SYS_FS_ENTRY handle, rsi = dest buf, rdx = buf size
syscall                         ; SYS_FS_READ
cmp     dword [rsi], EXPECTED_MAGIC
jne     .reject
```

Recommended scratch arenas (constants in your kernel headers):

```
PALETTE_BUF   = 56 B  (one palette)
FONT_BUF      = 16 KB (largest font + slack)
ICON_BUF      = 16 KB per slot (largest 48x48 BGRA + slack)
```

---

## 5. Embedding as `.inc`

The smaller resources ship as NASM include files inside `KERNEL.BIN`:

- `palette_light.inc`, `palette_dark.inc` - semantic constants + binary data
- `font_8x16.inc`, `font_16x32.inc`, `font_24x48.inc` - byte-identical to the `.nft` files

Icons at 32bpp are larger (10 icons × 3 sizes ≈ 140 KB), so they're loaded from FAT16 at runtime rather than embedded.

---

## 6. Versioning

The trailing `1` in each magic (`NPL1`, `NIC1`, `NFT1`) is the format version. Bumping to `NPL2` / `NIC2` / `NFT2` is the only forward-compat protocol - old kernels reject by magic mismatch, no ambiguity.
