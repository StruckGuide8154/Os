# Grit Design System Resources

This directory is the source-owned copy of the dropped `Grit Design System.zip`.

- `*.npl` and `palette_*.inc` define semantic light/dark palette tokens.
- `font_*.nft` and `font_*.inc` define fixed-size bitmap fonts.
- `icons/*.nic` provides 16px, 32px, and 48px 32bpp BGRA icons.
- `FORMAT.md` is the resource ABI reference.

The kernel embeds the current light/dark palettes, 8x16 UI font payload, and all
NIC icon sizes through `src/kernel/gui/resources.asm`.
