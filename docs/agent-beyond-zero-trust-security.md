# Beyond-Zero-Trust Security Roadmap for GritHL/GHL

Scope: GritHL/GHL only. This note describes the desired security architecture
for new high-level language, compiler, package, app, and release work. It does
not authorize changes to boot, kernel, driver, or legacy assembly surfaces.

## Non-negotiable Implementation Rule

No new implementation path described here may use assembly.

- No `.asm` files.
- No `.inc` files.
- No inline `asm` blocks.
- No generated assembly as a reviewed or trusted artifact for new security
  mechanisms.
- No "temporary" assembly shim for key handling, verification, packaging,
  signing, or policy enforcement.

If a required primitive cannot be expressed in GritHL/GHL or a memory-safe host
tool, the work is blocked until the primitive has a typed, audited high-level
interface with narrow authority and tests. Legacy generated NASM may remain as
part of the existing build pipeline, but this roadmap does not add to it and
does not depend on hand-written assembly.

## Security Objective

Move GritHL/GHL from "do not trust app code" to "assume any single layer can be
compromised and still preserve bounded damage." The model is inspired by seL4's
style of explicit authority, small verifiable interfaces, and invariants that
can be checked mechanically, but it is adapted for this project rather than
claiming formal seL4 equivalence.

The target state:

- Every authority is explicit, partitioned, signed, and revocable.
- Every compiled artifact, policy file, manifest, release bundle, and metadata
  index is signed.
- No release build emits telemetry, usage logs, diagnostic identifiers, or
  network callbacks by default.
- Compromise of one kernel service, one hypervisor layer, one signing key, or
  one maintainer account does not silently grant global authority.
- Maintainers can verify the security posture with repeatable gates before
  merge and before release.

## Threat Assumptions

This roadmap assumes stronger adversaries than ordinary zero-trust designs.

- A user app may be malicious.
- A GritHL/GHL package may be malicious.
- The compiler frontend may contain a bug.
- A maintainer workstation may be compromised.
- A build worker may be compromised.
- A hypervisor, emulator, firmware path, or host kernel may be compromised.
- One signing key may be stolen.
- One release mirror or distribution channel may serve stale or hostile data.
- A runtime kernel bug may allow memory corruption or confused authority.

The architecture does not assume a compromised CPU, broken cryptographic
primitive, or attacker control of every threshold key at once. Those are treated
as disaster recovery conditions rather than normal containment cases.

## Partitioned Authority

GritHL/GHL authority should be represented as small named capabilities, not as
ambient trust.

Required partitions:

- **Compile authority**: permission to compile a source package into an
  artifact. This does not imply permission to sign, publish, or run it.
- **Package authority**: permission to name dependencies, import modules, and
  expose public APIs. This does not imply runtime device or syscall authority.
- **Runtime authority**: permission to request specific syscall classes,
  storage namespaces, UI surfaces, IPC peers, and device abstractions.
- **Release authority**: permission to bless a manifest for distribution. This
  does not imply permission to change source or compiler policy.
- **Recovery authority**: permission to revoke keys, freeze channels, or rotate
  trust roots. This must be separate from day-to-day release authority.

Rules:

- Authority is deny-by-default.
- Capability names must be stable, reviewable, and narrower than the resource
  they protect.
- Capabilities are attached to signed manifests, not inferred from code shape.
- A package receives only the capabilities declared in its manifest and approved
  by policy.
- A compiler optimization must not widen authority, erase policy checks, or
  merge partitions.
- Cross-partition calls must pass through typed interfaces that validate
  handles, lengths, ownership, and lifetime.

For GritHL/GHL apps, syscall wrappers remain the only supported runtime
boundary. Future wrappers should be grouped by capability class so an app can
request, for example, window drawing without receiving filesystem or device
access.

## Capability Manifest Shape

Each package should eventually carry a signed policy manifest with at least:

- Package identity and version.
- Source digest set.
- Compiler version and policy version.
- Requested compile-time capabilities.
- Requested runtime capabilities.
- Declared dependencies with exact digests or transparency-log references.
- Public entry points and callback signatures.
- Reproducible-build recipe.
- Privacy declaration proving release builds have no logging or telemetry.
- Revocation and expiry metadata.

Manifests should be canonicalized before signing. Any non-canonical duplicate
key, ambiguous encoding, missing field, or unknown critical extension must fail
closed.

## Threshold Signing

No single key should be able to ship trusted GritHL/GHL software.

Required signing classes:

- **Source attestation key**: signs reviewed source snapshots.
- **Compiler attestation key**: signs compiler binaries or host-tool digests.
- **Policy key**: signs capability policy and allowed unsafe-equivalent
  high-level primitives.
- **Build attestation key**: signs reproducible build outputs from independent
  builders.
- **Release key**: signs the final channel manifest.
- **Recovery key**: revokes or rotates keys and can freeze a channel.

Minimum roadmap target:

- Development channel: 2-of-3 release quorum plus one independent build
  attestation.
- Stable channel: 3-of-5 release quorum plus two independent build
  attestations that match by digest.
- Recovery action: 2-of-3 recovery quorum, with recovery keys stored separately
  from release keys.

Key containment rules:

- A stolen source key cannot publish.
- A stolen release key cannot alter source, compiler policy, or build outputs.
- A stolen build key cannot bless a release alone.
- A stolen recovery key cannot publish code.
- Key rotation must not require trusting the possibly compromised key being
  replaced.

## Signed Everything

The release system should reject unsigned or partially signed state.

Artifacts requiring signatures:

- GritHL/GHL source snapshots.
- Package manifests.
- Capability policy files.
- Compiler/toolchain binaries or source digest pins.
- Generated package indexes.
- Build recipes.
- Build logs when retained for audit.
- Reproducible build attestations.
- App bundles.
- Release manifests.
- Revocation lists.
- Documentation that defines security policy.

Verification order:

1. Verify trust-root metadata and revocation state.
2. Verify threshold quorum for the release manifest.
3. Verify package index signatures.
4. Verify source, dependency, compiler, and policy digests.
5. Rebuild or verify independent build attestations.
6. Verify app bundle signatures.
7. Verify runtime capability grants before launch.

Any missing signature, stale timestamp, revoked key, digest mismatch, or
unrecognized critical policy extension fails closed.

## Release Privacy and No Logging

Release builds must be private by construction.

Rules:

- No telemetry.
- No analytics.
- No usage logging.
- No crash upload.
- No unique installation identifier.
- No background network callback.
- No package-manager contact except explicit user-initiated update checks.
- No release-build serial traces containing user data, app names, file paths,
  typed text, device identifiers, or stable hardware fingerprints.
- Debug logging must be compile-time gated and absent from release artifacts.

Privacy verification should include:

- Static scan for logging, telemetry, networking, and persistent identifier
  APIs in GritHL/GHL host tools and packages.
- Manifest field requiring an explicit `release_privacy = "no_logging"` style
  declaration.
- Release gate that rejects debug flags, trace sinks, or diagnostic channels.
- Reproducible check that the release artifact does not contain debug strings
  or telemetry endpoints.

If diagnostics are needed, they should be local, opt-in, user-visible, and
separately signed as a debug build.

## Compromise Containment

### Compromised GritHL/GHL App

Expected containment:

- App can use only granted runtime capabilities.
- App cannot invent syscall authority.
- App cannot access another app's storage namespace without an explicit shared
  handle.
- App cannot modify its signed manifest or capability set after approval.
- App cannot emit hidden logging in release mode without failing privacy gates.

### Compromised Compiler Frontend

Expected containment:

- Independent builder attestations catch output divergence.
- Source digest, compiler digest, policy digest, and output digest are linked in
  signed provenance.
- Security-critical compiler changes require policy-key approval.
- New primitives require tests proving fail-closed behavior.
- Generated output is treated as build output, not as a trusted source of
  policy.

### Compromised Kernel

The kernel remains inside the trusted computing base for runtime isolation, so
a fully compromised kernel can violate process memory and syscall boundaries.
The roadmap still reduces follow-on damage:

- Release signing keys are never present in the running OS image.
- Package signing and recovery keys are never available to app runtime.
- App manifests and release metadata are immutable signed inputs, so compromise
  can be detected after recovery.
- Runtime secrets are partitioned per app and per capability class where
  possible.
- On next trusted boot or external verification, tampered packages fail
  signature or transparency checks.

### Compromised Hypervisor, Emulator, or Host Kernel

The hypervisor or host can observe or alter a build/test VM. Containment
requires diversity and attestations:

- Stable releases require independent builders on separate administrative
  domains.
- Matching output digests are required before release.
- A single compromised VM cannot create a valid stable release quorum.
- Build recipes must be deterministic and signed so replay is possible on clean
  infrastructure.
- Test results from one host are advisory unless backed by signed build
  attestations.

### Compromised Signing Key

Expected containment:

- Threshold signing prevents one key from shipping alone.
- Revocation lists are signed by recovery quorum.
- Package and release metadata include key IDs, expiry, and signing purpose.
- Keys are scoped by role and channel.
- Emergency freeze metadata can stop a channel without publishing replacement
  code.

## Verification Gates

Merge gates for GritHL/GHL security changes:

- Documentation updated for every new capability, primitive, manifest field, or
  signing rule.
- No new `.asm` or `.inc` path introduced.
- No inline `asm` in any proposed new GritHL/GHL implementation.
- Compiler rejects unknown critical policy fields.
- Compiler rejects undeclared capabilities.
- Runtime launcher rejects unsigned or over-authorized packages.
- Privacy scan passes for release mode.
- Negative tests prove malformed manifests and missing signatures fail closed.

Release gates:

- Source, policy, compiler, package, and release signatures verify.
- Required threshold quorum is present.
- Revocation state is fresh.
- Independent build attestations match final artifact digests.
- Reproducible build recipe is signed and replayable.
- Release privacy gate proves no logging or telemetry path is present.
- Capability diff from previous release is reviewed and signed.
- Documentation defining security behavior is included in the signed release
  metadata.

Regression tests should include:

- Missing signature.
- Wrong signature purpose.
- Revoked key.
- Expired key.
- Duplicate manifest field.
- Unknown critical extension.
- Dependency digest mismatch.
- Runtime capability requested but not granted.
- Release artifact built with debug logging enabled.
- Attempted use of inline assembly or assembly source in the new path.

## Maintainability Rules

Security mechanisms must stay small enough to audit.

- Prefer one clear manifest format over multiple equivalent encodings.
- Keep policy evaluation deterministic and side-effect free.
- Keep capability names stable; deprecate with signed policy rather than
  silently changing meaning.
- Keep signing code separate from package parsing and compiler optimization.
- Keep recovery tooling minimal, documented, and tested offline.
- Keep release privacy checks automated, not dependent on manual review.
- Keep security docs normative: if behavior changes, docs change in the same
  review.
- Avoid clever compression, implicit defaults, or environment-dependent policy.
- Add new authority only with a threat model, negative tests, and revocation
  story.
- Treat maintainability as part of containment: confusing policy is a security
  bug.

## Phased Roadmap

### Phase 1: Policy Inventory

- Define the initial GritHL/GHL capability namespace.
- Define canonical manifest encoding.
- Document current runtime syscall groups and map them to future capability
  classes.
- Add docs-only review rules for no assembly in new security paths.

### Phase 2: Signed Manifests

- Implement manifest parsing in a high-level host tool.
- Add canonicalization tests and malformed-input tests.
- Require source digest and capability declarations for packages.
- Fail closed on unknown critical fields.

### Phase 3: Threshold Release Metadata

- Add role-separated key metadata.
- Require threshold signatures for package indexes and release manifests.
- Add revocation and expiry checks.
- Add independent build attestation records.

### Phase 4: Runtime Capability Enforcement

- Bind signed package manifests to app launch.
- Check runtime capabilities before syscall wrapper exposure.
- Reject packages whose requested authority exceeds policy.
- Add negative tests for over-authorized apps.

### Phase 5: Privacy-Hardened Releases

- Make release privacy declaration mandatory.
- Add static and artifact-level scans for logging and telemetry.
- Reject release builds with debug traces, serial user-data output, or network
  callbacks.
- Keep diagnostics as explicit debug artifacts outside the stable channel.

### Phase 6: Compromise Drills

- Rehearse stolen source key, build key, release key, and recovery key
  scenarios.
- Rebuild stable releases from independent infrastructure.
- Verify channel freeze and key rotation without trusting the compromised key.
- Record drill outputs as signed audit artifacts.

## Acceptance Criteria

The roadmap is complete when a GritHL/GHL stable release can prove:

- No new implementation path used `.asm`, `.inc`, or inline `asm`.
- Every artifact needed to build, verify, install, and launch is signed.
- Stable release approval required threshold quorum.
- At least two independent build attestations matched the final artifact digest.
- Runtime capabilities are explicit and deny-by-default.
- Release builds contain no logging or telemetry.
- A single compromised app, builder, maintainer key, host kernel, or hypervisor
  cannot silently publish or persist globally trusted code.
- Recovery can revoke compromised keys and freeze a channel with signed
  metadata.
