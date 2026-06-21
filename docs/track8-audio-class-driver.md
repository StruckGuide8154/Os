# Track 8 - HD Audio CLASS Driver (one driver, ~90% of machines, ring-3)

> Design + status for the audio driver. Topology truth is
> `docs/architecture-userspace-drivers.md` (the driver-host broker, G1-G4); this
> doc is the audio-specific realization. Read `docs/TODO-INDEX.md` first.

## Goal

Full-quality audio that **works off the bat** on the large majority of machines
with **no per-system driver** - and which fits the Track-8 contract: a ring-3,
default-deny, capability-gated process that holds no ambient hardware authority
(`src/drivers/audio/hda.ghl`, compiled `--target driver`).

## Why "one driver, ~90% coverage" is real engineering for audio

Audio is the rare device class where this is achievable rather than aspirational,
because the industry already did the standardization:

1. **Intel HD Audio (HDA / "Azalia"), spec rev 1.0a** standardizes the
   *controller*. Essentially every PCI/PCIe sound controller since ~2004 (Intel,
   AMD, NVIDIA, VIA) exposes the same fixed register layout (GCTL/CORB/RIRB,
   stream descriptors, BDL DMA). One controller driver speaks to all of them.
2. **Codecs are enumerable, not per-model code.** The attached Realtek/Conexant/
   IDT/... codecs are walked over the CORB/RIRB *verb* interface: root node ->
   Audio Function Group -> widgets (DACs, ADCs, pins, mixers). You find a DAC,
   route it to an output-capable pin, set the format, and play. No vendor table
   is consulted on the generic path.
3. **PCM is uncompressed - there is no software codec in the driver.** "Codecs"
   here are *hardware* converters configured over the same verb interface. Full-
   quality stereo PCM playback = enumerate widgets + push frames over a Buffer
   Descriptor List (BDL) to the controller's DMA engine. That is the 80% case.
4. **USB Audio Class (UAC1/UAC2)** covers essentially all USB DACs/headsets/
   interfaces with the same "class spec, not per-device" property, riding the
   xHCI work (Track 8 Rung 5). Companion module, same broker.

**Coverage map:** HDA class driver + UAC class driver ≈ 90%+ of machines, with no
per-system code.

### The honest ~10%

- **HDMI/DisplayPort audio** rides the GPU, not HDA pins. Per-vendor GPU bring-up
  is deprecated (`deprecated/780M_IGPU/`), so HDMI audio is out of scope; analog
  + USB covers the daily-driver case.
- **Jack re-tasking / speaker-amp enable** is the long tail (some laptops need a
  vendor verb, or an external I2C amp like TAS2563/CS35L41). The generic verb
  walk gets *working* output everywhere; the exceptions are patched by a **signed
  quirk table (data, not code)** - the same doctrine Linux's `patch_realtek.c`
  quirk tables encode, but kept as signed data so the driver stays generic and
  maintainable. Generic path works; quirks are additive.

Modeled on the public behaviour of Linux `sound/pci/hda` (`hda_intel.c` CORB/RIRB
+ stream setup, `hda_codec.c` node enumeration) and the HDA spec. The register
and verb constants are the standardized interface; no driver code is copied.

## Security: what code-exec in the audio driver buys an attacker (nothing)

The driver is `--target driver`: the compiler forces `--forbid-asm` +
`--deny-unsafe`, so it can declare no unsafe capability and emit no privileged
intrinsic (G1, enforced in `gritc.py` + `tests/ghl_kernel/driver_target_*.ghl`).
Every controller access is a `drvhost_*` broker syscall the kernel re-authorizes
against this driver's **signed grants**:

| Need | Grant | Broker enforcement |
|---|---|---|
| Controller registers | one 16 KB MMIO window at the PCI BAR | `drvhost_mmio_*` bounds-checks every access vs the granted `{base,len}` |
| CORB/RIRB rings + BDL + PCM buffer | one coherent DMA window | `drvhost_grant_dma` mints it; `drvhost_dma_contained` proves any base/len programmed into a DMA register lies inside it |
| Stream-complete interrupt | one IRQ vector | `drvhost_grant_irq` + forwarded ring signal; ISR logic runs ring-3 |

Audio is a classic DMA-attack vector (a malicious BDL pointing the engine at
arbitrary memory). Here the engine can reach **only** the granted audio buffer:
`INV-DRIVER-NO-DMA-MINT` (Track 3) extends to the new DMA grant table, so a
compromised driver's worst case is scribbling its own sound buffer.

## Why audio is the right *second* migration (Rung 2.5)

It exercises the hard mechanism - **DMA descriptor rings** (HDA's BDL maps
directly onto the broker's DMA grant + the validate-once fast path) - but off the
input/display latency-critical path, so a bug is low-blast-radius. It is a better
proving ground for DMA brokering than the NIC and lands before the latency-
critical input/display rungs.

## Module map

- `src/drivers/audio/hda.ghl` - the class driver (this track). Bring-up:
  controller reset -> CORB/RIRB DMA rings -> codec discovery (STATESTS -> AFG ->
  widget scan for a DAC + output pin) -> route + unmute -> 2-entry BDL over a
  double-buffered PCM ring -> start the output stream.
- `src/kernel/grithlk/driver_host.ghl` - broker; this track added the DMA grant
  table (`drvhost_grant_dma` / `drvhost_dma_contained`) the BDL needs.
- (future) `src/drivers/audio/uac.ghl` - USB Audio Class, over xHCI (Rung 5).
- (future) signed quirk table for jack/amp exceptions.

## Status

- [x] G1 compiler gate: `gritc --target driver` (forces forbid-asm + deny-unsafe;
      privileged intrinsics already require `--target kernel`). Tests:
      `tests/ghl_kernel/driver_target_{ok,no_io,no_mmio}.ghl` in
      `scripts/test/test_gritc_security.ps1`.
- [x] Broker DMA grant table + `drvhost_dma_contained` bounds check.
- [x] HDA class driver: controller reset, CORB/RIRB rings, generic codec/widget
      enumeration, path routing, BDL double-buffer, stream start. Compiles
      `--target driver` (broker-only; asserted in the security guard).
- [ ] Wire the `SC_DRVHOST_*` syscall family into the dispatcher (shared Rung-1
      work) so the driver can actually call the broker at runtime.
- [ ] Capture path (ADC + input pin) and a small ring-3 mixer above the driver.
- [ ] Signed quirk table for jack-retask / amp-enable exceptions.
- [ ] UAC (USB Audio Class) companion over xHCI.
- [ ] QEMU phase: `-device intel-hda -device hda-output` enumerates + plays PCM
      sourced from ring 3; perf gate vs an in-kernel baseline.
