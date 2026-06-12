# XML parser fixtures

Inputs consumed by the kernel-side XML self-test (to be wired into the
boot smoke run in a follow-up session). Filenames prefixed with `0N_` are
well-formed and must parse cleanly. Filenames prefixed with `bad_` must
fail with a specific error code from `xml_last_error`:

| File                 | Expected error code |
|----------------------|---------------------|
| bad_unclosed.xml     | 4 (mismatched close tag) |
| bad_entity.xml       | 8 (bad entity)            |
| bad_multiroot.xml    | 9 (multiple roots)        |

For well-formed inputs the harness should validate:
- `xml_root()` returns a valid node index.
- Root tag name matches expected (e.g. `root`, `svg`, `doc`, `a`).
- DOM walk via `xml_first_child` / `xml_next_sibling` reaches every
  expected child in source order.
- Entity decoding produces the expected bytes (`&amp;` -> `&`,
  `&#65;` -> `A`, `&#x42;` -> `B`, and internal-DTD custom entities
  such as `<!ENTITY brand "Grit">`).
- CDATA preserves `<`, `&`, `>` literally.

These fixtures are designed to be small enough that the smoke run can
embed them as initialised data in the kernel image without needing FAT
read paths during boot.
