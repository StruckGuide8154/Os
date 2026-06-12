# UEFI USB Mouse Input - Working Method (Acer Nitro V16 AI / Strix Point)

This is the **exact, verified-working** sequence to get USB mouse movement on
real hardware while inside UEFI Boot Services. Implement it 1:1 and the mouse
works first try.

Hardware proven on: Acer Nitro V16 AI (ANV16-42), AMD Ryzen AI 9 HX (Strix
Point), Radeon 890M, Insyde UEFI firmware.

---

## TL;DR - why earlier attempts failed

| Attempt | Result | Reason |
|---|---|---|
| `EFI_SIMPLE_POINTER_PROTOCOL.GetState()` | **hangs forever** | Firmware SPP `GetState` blocks even when `CheckEvent(WaitForInput)` says ready. Unusable. Do not call it. |
| `EFI_ABSOLUTE_POINTER_PROTOCOL.GetState()` | unreliable | Same firmware class. Skipped. |
| `UsbSyncInterruptTransfer`, `DataLength=8` | `EFI_INVALID_PARAMETER` | `DataLength` **must equal the endpoint `wMaxPacketSize`** (was 5, not 8). |
| `UsbAsyncInterruptTransfer` alone | registers `rc=0` but **callback never fires** | The firmware's own USB HID driver owns the interrupt endpoint. |
| `UsbAsyncInterruptTransfer` **after `DisconnectController`** | **WORKS** | Detaching the firmware driver hands us the endpoint. |

**The one critical step everyone misses: `DisconnectController` on the USB
interface handle before arming your own transfer.**

---

## Constraints

- This uses the **firmware's xHCI stack** via `EFI_USB_IO_PROTOCOL`. It only
  works **before `ExitBootServices()`**. After ExitBootServices the firmware
  USB stack is gone and you must use your own xHCI driver.
- Never call `ExitBootServices` if you want to keep using this path.

---

## Required table offsets (x86-64 UEFI)

```
EFI_BOOT_SERVICES:
  Stall                  = 248
  DisconnectController   = 272
  OpenProtocol           = 280
  LocateHandleBuffer     = 312

EFI_USB_IO_PROTOCOL vtable (byte offsets):
  UsbControlTransfer         =  0
  UsbAsyncInterruptTransfer  = 16
  UsbSyncInterruptTransfer   = 24
  UsbGetInterfaceDescriptor  = 64
  UsbGetEndpointDescriptor   = 72

EFI_USB_INTERFACE_DESCRIPTOR:
  +2 bInterfaceNumber   +4 bNumEndpoints
  +5 bInterfaceClass    +6 bInterfaceSubClass   +7 bInterfaceProtocol

EFI_USB_ENDPOINT_DESCRIPTOR:
  +2 bEndpointAddress   +3 bmAttributes
  +4 wMaxPacketSize (UINT16)   +6 bInterval
```

`EFI_USB_IO_PROTOCOL_GUID = 2B2F68D6-0CD2-44CF-8E8B-BBA20B1B5B75`

---

## The procedure

### 1. Enumerate USB IO handles

```
BS->LocateHandleBuffer(ByProtocol, &EFI_USB_IO_PROTOCOL_GUID, NULL,
                       &count, &handle_array);
```

### 2. For each handle - find a HID pointer interface

```
BS->OpenProtocol(handle, &USB_IO_GUID, &usbio, ImageHandle, NULL,
                 EFI_OPEN_PROTOCOL_GET_PROTOCOL /* = 2 */);

usbio->UsbGetInterfaceDescriptor(usbio, &ifd);     // vtbl +64
if (ifd.bInterfaceClass    != 3) skip;             // 3 = HID
if (ifd.bInterfaceProtocol == 1) skip;             // 1 = keyboard, not a mouse
```

### 3. Find the IN interrupt endpoint

```
for ep in 0 .. ifd.bNumEndpoints-1:
    usbio->UsbGetEndpointDescriptor(usbio, ep, &epd);   // vtbl +72
    if ((epd.bmAttributes & 3) != 3) continue;          // 3 = interrupt
    if (!(epd.bEndpointAddress & 0x80)) continue;       // 0x80 = IN
    -> found. Save:
       ep_addr  = epd.bEndpointAddress      (e.g. 0x81)
       maxpkt   = epd.wMaxPacketSize        (e.g. 5  - NOT always 4/8!)
       interval = epd.bInterval
       iface    = ifd.bInterfaceNumber
```

### 4. ★ DETACH THE FIRMWARE DRIVER  ★  (the step that makes it work)

```
BS->DisconnectController(handle, NULL, NULL);
// ControllerHandle = the USB interface handle
// DriverImageHandle = NULL  -> disconnect ALL drivers
// ChildHandle       = NULL
// rc = 0 on success. On this firmware it does NOT hang the xHCI host.
```

After this, the firmware's HID driver no longer owns the interrupt endpoint -
`EFI_USB_IO_PROTOCOL` itself stays valid (it is produced by the USB bus
driver, which is not disconnected).

### 5. SET_PROTOCOL (boot) and SET_IDLE(0)

`EFI_USB_DEVICE_REQUEST` is `{u8 RequestType; u8 Request; u16 Value; u16 Index; u16 Length}`.

```
SET_PROTOCOL:  RequestType=0x21  Request=0x0B  Value=0  Index=iface  Length=0
SET_IDLE:      RequestType=0x21  Request=0x0A  Value=0  Index=iface  Length=0

usbio->UsbControlTransfer(usbio, &request,
                          EfiUsbNoData /* = 2 */, 100 /*ms*/,
                          NULL, 0, &status);          // vtbl +0
```

Both must be sent. SET_IDLE matters - some mice will not report without it.

### 6. Arm the async interrupt transfer

```
usbio->UsbAsyncInterruptTransfer(
    usbio,
    ep_addr,            // includes the 0x80 IN bit
    TRUE,               // IsNewTransfer
    8,                  // PollingInterval, ms
    maxpkt,             // DataLength == wMaxPacketSize  (critical)
    &mouse_callback,    // InterruptCallBack
    NULL);              // Context
// vtbl +16,  rc = 0 on success
```

### 7. The callback (EFIAPI calling convention)

```
EFI_STATUS EFIAPI mouse_callback(
    VOID  *Data,        // rcx - the HID report
    UINTN  DataLength,  // rdx
    VOID  *Context,     // r8
    UINT32 Status);     // r9
```

- Runs at TPL_NOTIFY. Keep it tiny: copy `Data[0..DataLength]` into a buffer,
  set a "new report" flag, return `EFI_SUCCESS`. **Make no firmware calls.**
- If `DataLength == 0` (status-only callback), just return.

Boot-protocol mouse report layout (after SET_PROTOCOL boot):

```
byte0 = buttons   (bit0 L, bit1 R, bit2 M)
byte1 = dX        (signed int8)
byte2 = dY        (signed int8)
byte3 = wheel     (signed int8, if maxpkt >= 4)
```

Apply `mouse_x += (s8)byte1;  mouse_y += (s8)byte2;` then clamp.

### 8. Let the callback fire

The callback is driven by the firmware's xHCI timer event. It dispatches
whenever your code is at TPL_APPLICATION and you yield. A plain main loop that
calls `BS->Stall(10000)` (~10 ms) per iteration is enough - the callback fires
between iterations. Do **not** raise TPL.

---

## Robustness notes (do these - they prevented real freezes)

1. **Never call SPP / AbsolutePointer `GetState`** on this firmware. They block
   forever. If you must probe them, gate every call behind
   `BS->CheckEvent(protocol->WaitForInput)` and skip `GetState` unless the
   event is signalled - but on this hardware even that hung, so just don't.
2. **Arm every HID pointer interface**, not just the first match. There were 8
   USB interfaces; the real mouse was not guaranteed to be first. Run steps
   3-6 for *every* class-3, protocol≠1 interface. One shared callback is fine.
3. `UsbSyncInterruptTransfer` also works as a fallback once the driver is
   detached - but `DataLength` MUST equal `wMaxPacketSize`, and it should have
   a real timeout (e.g. 20 ms) so it cannot block.
4. Touchpad is **I²C-HID, not USB** on this laptop - it will never appear on
   the `EFI_USB_IO_PROTOCOL` path. Handle it separately.

---

## Minimal checklist to "works first try"

- [ ] `LocateHandleBuffer` for `EFI_USB_IO_PROTOCOL`
- [ ] For each handle: `OpenProtocol` (GET_PROTOCOL)
- [ ] `UsbGetInterfaceDescriptor` → class==3, protocol!=1
- [ ] `UsbGetEndpointDescriptor` → interrupt + IN endpoint; save addr/maxpkt
- [ ] **`DisconnectController(handle, NULL, NULL)`**  ← do not skip
- [ ] `UsbControlTransfer` SET_PROTOCOL(0) + SET_IDLE(0)
- [ ] `UsbAsyncInterruptTransfer(TRUE, 8ms, maxpkt, callback, NULL)`
- [ ] EFIAPI callback copies report; parse byte1/byte2 as signed dX/dY
- [ ] Main loop calls `BS->Stall` so callbacks dispatch
- [ ] Stay in Boot Services (no `ExitBootServices`)

Reference implementation: `src/diag/uefi_mouse_probe.asm`.
