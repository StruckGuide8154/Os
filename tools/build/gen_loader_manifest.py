#!/usr/bin/env python3
"""Generate immutable artifact commitments embedded in BOOTX64.EFI."""

import argparse
import hashlib
from pathlib import Path

ARTIFACTS = (
    ("kernel", "KERNEL.BIN"),
    ("apps", "APPS.BIN"),
    ("data", "DATA.IMG"),
    ("kernenv", "KERNEL.ENV"),
    ("syssig", "SYSSIG.ENV"),
)


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--esp", required=True, type=Path)
    parser.add_argument("--out", required=True, type=Path)
    parser.add_argument("--version", required=True, type=int)
    args = parser.parse_args()
    if args.version <= 0:
        raise SystemExit("release version must be positive")

    lines = [
        "; Auto-generated. Exact release artifacts pinned by BOOTX64.EFI.",
        f"LOADER_RELEASE_VERSION equ {args.version}",
    ]
    for label, name in ARTIFACTS:
        path = args.esp / name
        if not path.is_file():
            raise SystemExit(f"missing release artifact: {path}")
        data = path.read_bytes()
        digest = hashlib.sha256(data).digest()
        lines.append(f"loader_expected_{label}_size equ {len(data)}")
        lines.append(f"loader_expected_{label}_sha256:")
        lines.append("    db " + ", ".join(f"0x{byte:02x}" for byte in digest))

    args.out.parent.mkdir(parents=True, exist_ok=True)
    args.out.write_text("\n".join(lines) + "\n", encoding="ascii")
    print(f"loader-manifest: pinned {len(ARTIFACTS)} artifacts at version {args.version}")


if __name__ == "__main__":
    main()
