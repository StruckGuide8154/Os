# Security Policy

GritOS is a hobbyist x86-64 operating system written in assembly. Although it
is not production software, the project takes security research seriously and
welcomes good-faith reports of vulnerabilities in the OS, its build tooling, and
its supporting scripts.

## Supported Versions

GritOS is pre-1.0 and ships from a single mainline. Security fixes are applied
to the default branch (`master`); tagged prereleases are snapshots and are not
individually patched.

| Version            | Supported          |
| ------------------ | ------------------ |
| `master` (latest)  | :white_check_mark: |
| `v0.1.0-qrng` (pre-release) | :x: (snapshot - upgrade to `master`) |
| Older / forks      | :x:                |

## Reporting a Vulnerability

**Please report security vulnerabilities privately - do not open a public
issue, pull request, or discussion for a suspected vulnerability.**

Use this repository's **Private Vulnerability Reporting**:

1. Go to the **Security** tab of this repository.
2. Click **Report a vulnerability** (this opens a private advisory visible only
   to you and the maintainers).
3. Describe the issue with as much detail as you can (see below).

Direct link: https://github.com/StruckGuide8154/Os/security/advisories/new

If Private Vulnerability Reporting is ever unavailable, open a minimal public
issue that says only "requesting a private security contact" with **no
technical details**, and a maintainer will open a private channel.

### What to include

- A description of the vulnerability and its impact.
- Step-by-step reproduction (a PoC, build flags, QEMU/hardware setup, or a
  crashing input is ideal).
- Affected component(s) and commit hash / branch.
- Any suggested remediation, if you have one.

## Response Targets

This is a volunteer-run hobby project, so timelines are best-effort:

| Stage                              | Target            |
| ---------------------------------- | ----------------- |
| Acknowledge receipt                | within 7 days     |
| Initial assessment / triage        | within 14 days    |
| Status update cadence              | every 14 days     |
| Fix or mitigation for valid issues | within 90 days    |

We will credit reporters in the advisory unless you ask to remain anonymous.

## Scope

### In scope

- The GritOS kernel, boot path, drivers, and userspace under `src/`.
- Build and analysis tooling under `tools/` and `scripts/` (including the
  Python tooling and the QRNG seed tooling under `tools/quantum/`).
- Memory-safety, privilege-escalation, sandbox-escape (syscall capability /
  validation bypass), W^X / NX / SMEP / SMAP / CET bypass, and boot-integrity
  issues.
- Logic flaws in the security-relevant code paths (e.g. handle table, syscall
  dispatcher, measured boot, kernel lockdown).

### Out of scope

- Bugs that require physical access or an already-compromised host toolchain.
- Denial of service that only affects the reporter's own VM/hardware and has no
  privilege or isolation impact.
- Vulnerabilities in third-party dependencies that are already publicly known -
  report those upstream (Dependabot tracks our dependency updates).
- Findings from automated scanners with no demonstrated impact.
- Anything requiring social engineering of maintainers or users.
- Issues only reproducible on unsupported forks or modified builds.

## Safe Harbor

We support safe-harbor protections for good-faith security research. If you make
a good-faith effort to comply with this policy during your research, we will:

- Consider your research **authorized** with respect to any applicable
  anti-hacking laws, and will not initiate or support legal action against you
  for accidental, good-faith violations of this policy.
- Not pursue or support a claim under the DMCA (anti-circumvention) for your
  good-faith research.
- Work with you to understand and resolve the issue quickly, and recognize your
  contribution.

To qualify for safe harbor you must:

- Make a good-faith effort to avoid privacy violations, data destruction, and
  service interruption to others.
- Only test against your own instances/builds of GritOS - do **not** target
  other people's systems, infrastructure, or accounts.
- Report any vulnerability you discover promptly and give us reasonable time to
  remediate before public disclosure (we ask for coordinated disclosure).
- Not exploit a vulnerability beyond the minimum necessary to confirm it, and
  not exfiltrate, retain, or share data that is not your own.

If in doubt about whether a specific action is authorized, ask us first via the
Private Vulnerability Reporting channel above and we will clarify. This safe
harbor applies only to legal claims under the control of the GritOS
maintainers; it does not bind third parties.

## Coordinated Disclosure

We follow coordinated disclosure. Once a fix is available (or the response
window has elapsed), we will publish a GitHub Security Advisory crediting the
reporter. Please do not disclose publicly before then without coordinating with
us.
