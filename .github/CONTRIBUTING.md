# Contributing to Grit

Thanks for your interest in Grit, a hobbyist x86-64 operating system written
in assembly. Contributions, bug reports, and ideas are welcome.

## Security first

**Never report a security vulnerability in a public issue or pull request.**
Use this repository's Private Vulnerability Reporting (Security tab > *Report a
vulnerability*). See [SECURITY.md](SECURITY.md) for the full policy, scope, and
safe-harbor terms.

Never commit secrets, tokens, private keys, or credentials. Secret scanning and
push protection are enabled on this repository and will block such pushes.

## Development workflow

1. Fork the repo (or create a branch if you have write access).
2. The default branch is `master` and is protected: changes land via pull
   request. Direct pushes and force-pushes to `master` are blocked.
3. Open a PR against `master`. At least one approval and resolution of all review
   conversations are required before merge (the repository owner may bypass for
   solo maintenance).
4. CodeQL code scanning (Python tooling) and other checks must pass.

## Building & running

Grit targets UEFI (GOP framebuffer). Common entry points:

- Build: `scripts/build/build_uefi.ps1` (run from the repo root).
- Run in QEMU: `scripts/run/run_uefi.ps1`.
- Tests / probes: scripts under `scripts/test/`.

See `docs/STATUS.md` for architecture and current status.

## Code style

- Match the conventions of the surrounding assembly: naming, comment density,
  and structure.
- Keep changes focused; one logical change per PR.
- Update `docs/` when you change behavior that the docs describe.

## Python tooling

Tooling under `tools/` is Python/PowerShell. Python dependencies for the QRNG
tooling live in `tools/quantum/requirements.txt` and are tracked by Dependabot.
CodeQL scans the Python tooling for security issues.
