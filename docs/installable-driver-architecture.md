# Installable Driver and Device-Class Architecture

## Purpose

Grit should be able to install a driver for new hardware without rebuilding the
kernel, while applications and OS services remain independent of the driver and
device model. A mouse driver publishes pointer events, a NIC driver publishes an
Ethernet interface, and a Wi-Fi stack publishes a normal network interface. Their
consumers never call `rtl8156`, `xhci`, or a future Wi-Fi chipset driver directly.

This design extends the existing ring-3 driver-host architecture in
`architecture-userspace-drivers.md`. The driver-host remains the hardware security
boundary; this document adds package installation, device matching, permission
review, lifecycle management, and stable device-class contracts.

## Required properties

1. Drivers are signed, external packages and run only as ring-3 driver processes.
2. Installing a package does not grant it hardware access. Binding a verified
   package to a detected device creates the narrow, instance-specific grants.
3. Permissions are derived from the signed manifest and discovered hardware. The
   driver cannot widen them at runtime.
4. Each physical function has one exclusive owner unless a class contract explicitly
   supports sharing.
5. Applications use stable class services, never driver-specific entry points.
6. A driver can crash, be quarantined, updated, or replaced without corrupting the
   kernel or changing application APIs.
7. Unknown package, manifest, ABI, device, or permission combinations fail closed.

## Architecture

```text
 applications and OS services
        |  stable APIs: network, pointer, keyboard, block, audio, display
        v
 class brokers (ring 3, one contract per device class)
        |  typed messages, handles, bounded shared rings
        v
 driver processes (ring 3, one device instance or compartment per process)
        |  capability-bound driver-host requests
        v
 driver-host broker (ring 0, small TCB)
        |  bounded MMIO / PIO / DMA / IRQ / USB / PCI-config operations
        v
 physical or virtual hardware

 device manager (ring 3, control plane only)
        |-- verifies packages and compatibility
        |-- matches detected devices to packages
        |-- presents permission review
        |-- asks the kernel to spawn, bind, stop, update, or quarantine drivers
        `-- holds enumeration and lifecycle authority, not data-path authority
```

The device manager is not on the packet, input, audio, or display fast path. It
cannot read arbitrary MMIO or DMA memory. A compromised device manager may propose a
bad binding, but the broker still limits the resulting driver to the resources
authorized for that exact device instance and signed package policy.

## Driver package

Use a versioned `.gdrv` package carried inside the existing signed `ART_DRIVER`
envelope. The envelope supplies signature quorum, target-device binding, validity,
revocation epoch, and anti-rollback floors. Its payload contains:

```text
package_id             stable reverse-DNS-style identifier
package_version        monotonic package version
publisher_id           signer/publisher identity
driver_abi             required driver-host ABI range
class_abi[]            provided class and supported ABI range
match_rules[]          bus + class + vendor/product/revision/interface match
requested_resources[]  MMIO, PIO, DMA, IRQ, USB endpoints, PCI-config, reset
entrypoints[]           init, start, suspend, resume, stop, health
dependencies[]         optional class/service and minimum-version dependencies
firmware[]             signed hashes, device binding, and load constraints
binary_hash             exact GHL output image digest
policy_hash             exact permission policy digest
```

Match rules are data, not executable probe code. Initial buses are PCI, USB, and
ACPI. A package may contain several match rows, but every row names the same class
contract and each bound instance receives its own identity and grants.

Package admission and device binding are separate operations:

- **Install** verifies and stores an inert package. It grants no device access.
- **Bind** selects one detected device, computes concrete resources, obtains approval
  when needed, creates a driver process, and installs instance-specific grants.

This prevents a broadly compatible package from receiving authority over every
matching device merely because it was installed.

## Matching and binding

The device manager builds immutable device records from trusted enumerators:

```text
device_id, bus, topology_path, class, vendor, product, revision,
interfaces, BARs/endpoints, IRQ options, IOMMU group, hotplug generation
```

Candidate selection is deterministic:

1. Reject invalid signatures, revoked publishers, rollback versions, incompatible
   ABIs, and rules that do not match the immutable record.
2. Prefer an exact vendor/product/revision match over a range, then a standard
   class driver over a generic fallback only when its match specificity is equal.
3. Prefer the highest admitted package version from the configured trust channel.
4. Refuse ambiguous equal-ranked candidates and ask the user to choose.
5. Claim the device atomically, spawn the driver, establish class endpoints, and
   publish the class device only after its health check succeeds.

Binding is transactional. Failure tears down IRQ routes, DMA mappings, shared rings,
MMIO/PIO grants, and the process before releasing the device claim. Consumers never
observe a half-started class device.

## Permission review

The review UI shows the difference between the package's requested maximum and the
concrete authority calculated for this device. It uses plain categories plus exact
details:

- device identity and topology path;
- MMIO/PIO windows and whether they are read-only or writable;
- DMA size, direction, and IOMMU isolation status;
- IRQs or USB endpoints;
- firmware/reset authority;
- class services published;
- persistent storage, network, or credential access, if any;
- publisher, signature status, version, and update rollback policy.

Suggested review tiers:

- **Routine:** class-standard access confined to one device and broker-owned bounce
  buffers. A trusted publisher policy may pre-approve it.
- **Elevated:** device reset, firmware loading, writable PCI configuration, large DMA,
  or access spanning multiple functions. Requires an explicit review.
- **Forbidden by default:** arbitrary physical memory, raw kernel pointers, undeclared
  devices, unbounded DMA, or a wildcard I/O range.

An approval is bound to `{package hash, policy hash, device identity, concrete grant
set}`. Updating the binary or asking for more authority invalidates it. Reducing
permissions does not require a fresh escalation prompt.

On systems without an IOMMU, a device never receives arbitrary guest-physical
addresses. The broker uses bounded bounce buffers where practical; drivers that
cannot operate safely that way remain disabled with an honest explanation.

## Stable device-class contracts

Each class broker owns a small, versioned ABI. Drivers publish typed events and
operations through handles and bounded rings; function pointers and raw addresses do
not cross process boundaries.

Initial contracts:

| Class | Driver-facing contract | OS-facing result |
|---|---|---|
| `net.l2` | link state, MAC, TX frames, RX frames, MTU, counters | ordinary network interface |
| `input.pointer` | relative/absolute motion, buttons, wheel, capabilities | normalized pointer events |
| `input.keyboard` | scan usage, press/release, LED capability | normalized key events |
| `block` | geometry, flush, read/write request rings, media state | block-device handle |
| `audio.pcm` | formats, stream setup, buffer position, XRUN event | mixer endpoint |
| `display.scanout` | modes, surfaces, present, hotplug | display/output handle |
| `power.battery` | charge, state, rate, health events | power-status provider |
| `wlan.radio` | radio capabilities, scan results, management/data frames | private input to Wi-Fi service |

The existing `net_nic_*` dispatcher is the seed of `net.l2`, but its compiled-in
function-pointer table must become dynamic class registration and message/ring
dispatch. Protocol code continues to use the generic network interface.

Class ABI rules:

- negotiate a major/minor version during registration;
- reject unknown major versions;
- ignore only explicitly optional, length-delimited minor-version fields;
- include device generation on every handle so stale handles fail after restart;
- validate ring indices, descriptor counts, lengths, and ownership on both sides;
- apply backpressure and quotas so a driver cannot flood a broker;
- revoke all handles when a driver is quarantined or its device is unplugged.

## Wi-Fi integration

Wi-Fi should not expose chipset details to the network stack. Split it into three
parts:

```text
Wi-Fi application/settings
        | network choice and user intent
credential broker ------> Wi-Fi service/supplicant
        | opaque, scoped credential handle     |
        |                                      | wlan.radio ABI
        |                                      v
        |                              chipset driver package
        |                                      |
        `---------------- security policy -----+-- brokered device access

Wi-Fi service publishes net.l2 only after association succeeds
        v
existing ARP / DHCP / IPv4 / TCP and applications
```

The chipset driver handles device firmware, command/event rings, DMA, radio control,
and raw 802.11 transport. The Wi-Fi service handles scanning policy, association,
roaming, 802.11 state, WPA authentication, and conversion to an ordinary `net.l2`
interface. The credential broker releases a credential only to the approved Wi-Fi
service for the selected network; the chipset driver and applications do not receive
the saved secret directly.

This separation means a new Intel, Realtek, Atheros, USB, PCIe, or virtual Wi-Fi
driver implements `wlan.radio`; neither applications nor the IP stack change. A
driver may offload encryption to hardware, but the security state machine remains in
the Wi-Fi service so hardware offload is an implementation detail.

## Lifecycle, recovery, and updates

Every bound instance follows:

```text
DETECTED -> MATCHED -> REVIEWED -> SPAWNING -> HEALTHY -> PUBLISHED
                                         |         |
                                         v         v
                                      FAILED    QUARANTINED -> RESTARTING
                                                        |          |
                                                        `-> FAILED `-> HEALTHY
```

- Suspend, resume, hot-unplug, reset, update, and shutdown have bounded deadlines.
- The broker masks IRQs and revokes DMA before killing or replacing a driver.
- Restart creates a new generation; old class and DMA handles become invalid.
- Health checks are class-specific and cannot themselves grant more authority.
- Repeated failure keeps the device offline and preserves a small audit record.
- Updates start in a new process, pass health checks, then atomically replace the old
  class endpoint. Rollback is allowed only to a still-admitted version above the
  persistent security floor.

## Auditing

Record compact, bounded events for package admission, permission decisions, binding,
grant creation, denied broker requests, firmware loads, resets, faults, quarantine,
restart, update, and unbind. Logs contain identifiers, hashes, result codes, and
resource ranges—not packet contents, keystrokes, credentials, or user data.

## Implementation plan

### Stage 0: make the current broker real

- Wire `SC_DRVHOST_*` into the actual syscall dispatcher.
- Define driver slots and their outer syscall-capability manifest.
- Derive caller identity in the kernel; remove any API where a driver supplies the
  authoritative `driver_id` or `policy_grant` itself.
- Complete hostile-call tests for MMIO, PIO, DMA, IRQ, rings, reset, and PCI config.

This is the existing blocker for every current ring-3 driver and must land first.

### Stage 1: class ABI foundation

- [x] Specify and implement the common opaque handle, ABI-version, class-kind,
  owner, and restart-generation layout. Resolution authenticates every packed
  field against kernel-owned registry rows and live broker state; duplicate
  live owner/class publication is rejected.
- [~] Implement a class registry and one `net.l2` broker. The fixed-capacity
  multi-device registry, health-gated `net.l2` publication, MTU/feature
  metadata, quarantine revocation, and generation-safe TX resolution are live.
  Typed message/event layouts and moving the remaining legacy NIC ops consumers
  fully onto the handle API remain.
- Adapt RTL8139 or RTL8156 as the first end-to-end dynamic backend while keeping the
  existing IP stack unchanged.
- Test failover, duplicate registration, malformed descriptors, driver death, and
  stale handles.

### Stage 2: device manager and binding

- Generalize the existing GPU PnP ideas into bus-neutral PCI/USB/ACPI device records.
- Implement deterministic matching, exclusive claims, spawn/bind IPC, transactional
  teardown, and health-gated publication.
- Keep enumerators read-only; the broker, not PnP, mints concrete grants.

### Stage 3: external `.gdrv` packages

- Define and generate the package manifest.
- Admit it through the existing `ART_DRIVER` signed-envelope gate.
- Add a package store, permission-diff UI, approval records, revocation, and
  anti-rollback update flow.
- Add fixtures for tampering, wrong device, expired signatures, downgraded versions,
  widened permissions, ambiguous matches, and revoked publishers.

### Stage 4: input and other class drivers

- Add `input.pointer` and `input.keyboard`; migrate one mouse path first.
- Add battery, audio, block, and display contracts in increasing risk order.
- Delete each compiled-in driver only after its external replacement passes boot,
  hotplug, restart, latency, and negative-security tests.

### Stage 5: hardware Wi-Fi

- Implement `wlan.radio`, the credential broker, and the Wi-Fi service/supplicant.
- Choose the first chipset only after checking public documentation, redistributable
  firmware, available hardware, and whether safe DMA isolation is possible.
- Prefer a removable USB adapter for the first bring-up because failure and reset are
  isolated; then add a PCIe chipset using the same class contract.
- Gate completion on scan, WPA association, DHCP through `net.l2`, reconnect,
  suspend/resume, malformed firmware/device events, driver crash, and credential
  non-disclosure tests.

## First contribution boundary

Do not start with a chipset driver. First land Stage 0 and the common class ABI, then
prove `net.l2` using an existing RTL driver. That produces the reusable installable
driver path. The first Wi-Fi driver then becomes a package implementing one known
contract instead of a special case threaded through the kernel and applications.

## Implementation status

Foundation landed:

- `driver_host.ghl` is compiled and linked into the real kernel image.
- Syscall numbers `232..249` are present as a stable sparse driver ABI and gated by
  `CAP_DRIVER`, which no ordinary application manifest holds.
- Registration and data-plane wrappers derive driver identity from the authoritative
  caller slot. Signed policy and code identity live in kernel-owned broker rows.
- Ring batches receive whole-range dispatcher validation and SMAP bracketing.
- Driver-created grants, DMA mapping, IRQ waiting/routing, and cross-driver grants
  remain denied until the device-manager control plane provisions them safely.
- `net_driver.inc` defines the common version, handle, message, descriptor,
  `net.l2`, and `wlan.radio` ABI constants.
- `driver_host.ghl` implements the runtime class registry and positive 63-bit
  opaque handles. Restart generation is checked both in the packed handle and
  the live driver row; generation exhaustion fails closed instead of wrapping.
- The VirtIO ring-3 backend publishes `net.l2` only after its health check,
  DMA/IRQ setup, and MAC read succeed. TX resolves the handle and enforces its
  published MTU before crossing into the driver.
- `eval_drvclass_handles.py` proves packed-field forgery rejection, bounded
  metadata, quarantine revocation, stale-handle rejection after restart, fresh
  republish, and fail-closed generation exhaustion. Its planted-bug selftest
  demonstrates that the proof catches stale-handle revalidation.
- `test_driver_framework.ps1` permanently guards these properties in full verify.

Still required before an external driver can operate hardware end to end:

- external-package-backed driver-slot creation and full `ART_DRIVER` admission;
- typed class messages/events and conversion of remaining legacy NIC consumers
  to opaque `net.l2` handles;
- package storage, matching, review UI, update, revocation, and recovery lifecycle.
