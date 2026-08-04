# BenQ monitor DDC/CI integration reference

Technical reference for controlling a BenQ monitor from macOS over DDC/CI: the
transport, the packet formats, the VCP codes, and the hardware quirks that will
otherwise cost you a day each.

Everything here was validated live against a **BenQ MA320UP** (MCCS 2.2) on
Apple Silicon. The transport and the standard MCCS codes are generic and apply to
any DDC-capable display; the sections marked "BenQ quirk" are model specific and
should be re-verified on other panels.

## Contents

- [Summary](#summary)
- [Transport](#transport)
- [Packet formats](#packet-formats)
- [Finding and binding a display](#finding-and-binding-a-display)
- [Reliability rules](#reliability-rules)
- [VCP reference](#vcp-reference)
- [Capabilities string](#capabilities-string)
- [Gotchas](#gotchas)

## Summary

BenQ's own Display Pilot 2 controls these monitors with **standard DDC/CI (VESA
MCCS) over IOKit**. There is no proprietary USB or network protocol involved for
brightness, volume or input switching, so the whole feature set is reproducible
with the public IOKit path that `m1ddc`, `MonitorControl` and `BetterDisplay`
also use.

| Feature | VCP code | Range or values |
|---|---|---|
| Brightness | `0x10` | continuous, 0 to 100 |
| Contrast | `0x12` | continuous, 0 to 100 |
| Input source | `0x60` | discrete; see [input source](#input-source-0x60) |
| Volume | `0x62` | continuous, 0 to 50 on the MA320UP, read the max |
| Mute | `0x8D` | `0x01` mute, `0x02` unmute |
| Auto input switching | `0xF6` | `0x00` off, `0x01` on |
| MCCS version | `0xDF` | `0x0202` for 2.2 |

## Transport

**DDC/CI** (Display Data Channel Command Interface) is an I2C bus that rides the
display cable (HDMI, DisplayPort, USB-C DP-alt). **MCCS** (Monitor Control
Command Set) defines what each control means, addressed by a **VCP code**
(Virtual Control Panel). The monitor sits at 7-bit I2C address `0x37`.

Two host-side backends exist, chosen by platform:

1. **Apple Silicon**: the private `IOAVService` API, which is I2C over the DCP
   display coprocessor.
2. **Intel**: `IOFramebuffer` I2C requests with transaction type
   `kIOI2CDDCciReplyTransactionType`, falling back to `kIOSimpleTransactionType`,
   plus special handling for AMD framebuffers and bridged HDMI ports.

Both speak the identical DDC/CI packet format below; only the I2C call differs.
The Intel path here is documented from Display Pilot 2's own symbols and has not
been exercised; `ddcctl` is the canonical reference for it.

### Apple Silicon API

These IOKit symbols are private and unpublished, so declare them yourself (a
small Objective-C shim or a bridging header keeps the CoreFoundation ownership
rules out of Swift):

```c
typedef CFTypeRef IOAVServiceRef;

extern IOAVServiceRef IOAVServiceCreate(CFAllocatorRef allocator);
extern IOAVServiceRef IOAVServiceCreateWithService(CFAllocatorRef allocator, io_service_t service);
extern IOReturn IOAVServiceReadI2C (IOAVServiceRef service, uint32_t chipAddress, uint32_t offset,
                                    void *outputBuffer, uint32_t outputBufferSize);
extern IOReturn IOAVServiceWriteI2C(IOAVServiceRef service, uint32_t chipAddress, uint32_t dataAddress,
                                    void *inputBuffer,  uint32_t inputBufferSize);
```

Using private symbols is fine for a Developer ID app distributed outside the App
Store. The App Store sandbox blocks this path, so plan distribution accordingly.

### Constants

| Name | Value | Meaning |
|---|---|---|
| Chip address | `0x37` | DDC/CI I2C address, passed as `chipAddress` |
| Data address | `0x51` | DDC/CI offset, passed as `offset` or `dataAddress` |
| Source byte | `0x51` | Host address folded into the checksum |
| Destination byte | `0x6E` | Display address folded into the checksum |
| Alt read address | `0x50` | LG-style alternate reads only, not needed for BenQ |

Every packet is framed with a length byte and an XOR checksum over the
destination byte, the source byte and the payload.

## Packet formats

### Get VCP (read a control)

Write the request first, then read the reply. Reading without writing the request
returns stale data.

```
Request, via IOAVServiceWriteI2C(svc, 0x37, 0x51, data, len):
  data[0] = 0x82                                        // 0x80 | 2 bytes follow
  data[1] = 0x01                                        // Get VCP Feature opcode
  data[2] = <vcp code>                                  // e.g. 0x10 brightness
  data[3] = 0x6E ^ 0x51 ^ data[0] ^ data[1] ^ data[2]   // checksum

Reply, read 12 bytes via IOAVServiceReadI2C(svc, 0x37, 0x51, buf, 12):
  buf[6..7] = max value     (big-endian uint16)
  buf[8..9] = current value (big-endian uint16)
```

Always read the max from the reply rather than assuming 100. That is what makes
the same code work on a panel whose volume tops out at 50.

### Set VCP (write a control)

```
Write via IOAVServiceWriteI2C(svc, 0x37, 0x51, data, len):
  data[0] = 0x84                                        // 0x80 | 4 bytes follow
  data[1] = 0x03                                        // Set VCP Feature opcode
  data[2] = <vcp code>
  data[3] = (value >> 8) & 0xFF                         // high byte
  data[4] = value & 0xFF                                // low byte
  data[5] = 0x6E ^ 0x51 ^ data[0] ^ data[1] ^ data[2] ^ data[3] ^ data[4]
```

Set produces no reply. Re-read after a short delay to confirm the value took.

### Capabilities string (feature discovery)

Loop over offsets with opcode `0xF3` (request) and `0xE3` (reply) until a
fragment comes back empty.

```
Request:
  data[0] = 0x83                                        // 0x80 | 3 bytes follow
  data[1] = 0xF3                                        // Capabilities Request
  data[2] = (offset >> 8) & 0xFF
  data[3] = offset & 0xFF
  data[4] = 0x6E ^ 0x51 ^ data[0] ^ data[1] ^ data[2] ^ data[3]

Reply:
  reply[0]    = 0x6E                                    // source address
  reply[1]    = 0x80 | totalLen
  reply[2]    = 0xE3                                    // Capabilities Reply
  reply[3..4] = echoed offset
  reply[5...] = fragment bytes, payload = (reply[1] & 0x7F) - 3

  advance offset += payload; stop when payload <= 0
```

## Finding and binding a display

A control channel is one `IOAVServiceRef` bound to one external display. A
display is controllable only when all four of these hold, so check them in order:

1. **It is external.** Enumerate with `CGGetOnlineDisplayList` and exclude
   anything where `CGDisplayIsBuiltin(displayID)` is true.
2. **Its DDC channel resolves.** Walk the IORegistry for `DCPAVServiceProxy`
   nodes (or `AppleCLCD2` / external framebuffer nodes), pick the one whose
   `Location` is `External`, and call `IOAVServiceCreateWithService` on it. With a
   single external display, `IOAVServiceCreate(NULL)` is enough. Match by
   IORegistry path or EDID when there is more than one.
3. **It answers a probe.** Read `0xDF` (MCCS version) and require a well-formed
   reply; the MA320UP returns `0x0202`. Brightness `0x10` works as a fallback
   probe. Accept "uncontrollable" only after several failed attempts, never after
   the first.
4. **It advertises the code you want.** Parse the capabilities string and gate
   each control separately, so a panel without volume still gets brightness.

For display identity and per-monitor persistence, read vendor, model and serial
from `CoreDisplay_DisplayCreateInfoDictionary(displayID)` and key your storage on
the EDID UUID or serial. BenQ panels report EDID vendor id `BNQ`, but do not
hard-require it: any display that passes the probe is controllable.

Register `CGDisplayRegisterReconfigurationCallback` and re-run the checks on
every event. It fires on connect, disconnect, sleep, wake, resolution change and
rearrange. Re-probe when your UI opens as well, since a user toggling DDC/CI in
the monitor's OSD produces no callback. After wake, DDC needs a moment: retry
before concluding the display is gone.

When a display enumerates but fails the probe, the usual cause is DDC/CI switched
off in the monitor's own OSD (on BenQ, under System > DDC/CI), a non-DDC display,
or a KVM or adapter that blocks I2C. Surface that as a hint rather than a generic
failure.

## Reliability rules

DDC on these panels is not reliable per call. All four of these are load bearing:

- **Retry every read.** Empty or zero replies are common. Retry up to about 10
  times with 40 to 50 ms between attempts and accept the first well-formed reply.
- **Space out writes.** `m1ddc` sends each set twice with a 10 ms gap; some panels
  need more.
- **Coalesce during a drag.** A slider can otherwise emit dozens of writes per
  second. Keep only the latest value, rate limit to roughly one write per 30 to
  50 ms, and always send a final write on release so the end value is exact.
- **Validate the reply frame.** Check the opcode and echoed VCP code before
  trusting a value. A misaligned read surfaces the `0x6E` source byte as data.

## VCP reference

### Input source `0x60`

Discrete, and the messiest control on BenQ hardware. Confirmed map for the
MA320UP:

| Source | Write | Reads back as | Notes |
|---|---|---|---|
| USB-C | `0x13`, fallback `0x15` | `0x13` | OEM code, absent from the capabilities string. Writing `0x0F` does nothing. |
| HDMI 1 | `0x11` | `0x11` | Standard MCCS |
| HDMI 2 | `0x12` | `0x12` | Standard MCCS |

**BenQ quirk, phantom inputs.** The capabilities string advertises
`60(0F 11 12 15)`, but `0x0F` (a DisplayPort slot the model does not expose) and
`0x15` (a firmware-disabled Thunderbolt 3 input) are phantoms. Do not offer them
as pickable sources even though the monitor lists them.

**BenQ quirk, read/write asymmetry.** The value you read from `0x60` is not
necessarily the value you write to select that input. USB-C reads back as `0x13`,
which is not in the monitor's own settable list. Keep two maps, a write map
(label to value you send) and a read map (values that mean this input is active),
and let them differ.

**BenQ quirk, auto input switching fights you.** The panel's auto input detection
(`0xF6`) races a manual selection and reverts it. The switch sequence that works:

1. Write `0xF6 = 0x00` to disable auto switching.
2. Write `0x60 = <target>`.
3. Wait about 1.5 s. Do not read back immediately, the read lags the switch.
4. Re-read to confirm, re-write once if needed, then try the fallback value.

**Switching input can drop your control channel.** If you select an input with no
live source, the monitor stops displaying the Mac, and because DDC rides the
USB-C DisplayPort link, the control channel can disappear with it, leaving no way
to switch back in software. Confirm a source is live before switching to it, and
fail gracefully instead of retrying in a loop. The monitor's physical OSD buttons
are the only recovery.

### Brightness `0x10`

Continuous, 0 to 100. This is the panel's real backlight, independent of the
macOS brightness slider (which does nothing for most external displays).

Brightness is distinct from contrast `0x12`, which is also 0 to 100. Some picture
modes, HDR in particular, can lock or constrain brightness; if a write silently
reverts, a locked picture mode is the likely cause, which re-reading after the
write will detect.

### Volume `0x62` and mute `0x8D`

Continuous, **0 to 50** on the MA320UP, not 0 to 100. The max is confirmed by the
DDC reply and by Display Pilot 2's own model config (`MaxVolume=50`). Writing
values above the max is undefined behaviour: the panel may clamp, wrap or ignore.
Read the max from the reply and scale, falling back to 50 only if the read fails.

`0x62` sets the monitor's own speaker gain. It is independent of the macOS output
device, so if macOS is not outputting to the monitor the level still moves but
you hear nothing. That is expected.

Mute is `0x8D` (`0x01` mute, `0x02` unmute). Muting does not zero `0x62`, so
track level and mute state separately if you want unmute to restore the level.

## Capabilities string

Raw string from the MA320UP, the authoritative list of what it supports:

```
(prot(monitor)type(LCD)model(MA320UP)
 cmds(01 02 03 07 0C E3 F3)
 vcp(02 04 08 10 12 13(00 01) 14(04 05 08 0B) 16 18 19 1A
     59 5A 5B 5C 5D 5E 5F(00 02 03) 60(0F 11 12 15) 62
     67(00 01) 68(00 02 04 06 08 0A 0C 0E) 69(00 01) 6A(00 01)
     72(50 64 77 78 8C A0) 81(00 01 02) 86(01 02 05) 87 8D(01 02)
     94(01 02 03 04 05) 9B 9C 9D 9E 9F A0 AA(01 02 03) BE C1 C2 C9 CA
     CC(01 02 03 04 05 06 07 09 0A 0B 0D 0E 0F 10 12 14 17 1A 1E 1F 24)
     D6(50 60 90 A0) DC(0A 0F 12 1F 22 23 28 32) DF E5 EE(00 01 02)
     EF(00 01) F0(00 01 02) F6(00 01) F8(00 0A 14 1E) FD(00 03 04))
 mswhql(1) asset_eep(40) mccs_ver(2.2))
```

`cmds(...)` lists the supported DDC/CI operations, including `E3` and `F3`, the
codes used to read this very string.

### Decoded codes

Standard MCCS, or corroborated by Display Pilot 2's model config:

| VCP | Meaning | Values |
|---|---|---|
| `0x02` | New control value flag | |
| `0x04` | Restore factory defaults | |
| `0x08` | Restore factory color defaults | |
| `0x10` | Brightness | 0 to 100 |
| `0x12` | Contrast | 0 to 100 |
| `0x14` | Select color preset | `04 05 08 0B` |
| `0x16` `0x18` `0x1A` | Video gain R/G/B | 0 to 100 |
| `0x59` to `0x5E` | 6-axis saturation (R/Y/G/C/B/M) | |
| `0x60` | Input source | `0F 11 12 15` advertised |
| `0x62` | Audio volume | 0 to 50 |
| `0x87` | Sharpness | |
| `0x8D` | Audio mute | `01` mute, `02` unmute |
| `0x94` | Audio mode | `01 02 03 04 05` (Standard, Dialogue, Music, Cinema, Game) |
| `0x9B` to `0xA0` | 6-axis hue (R/Y/G/C/B/M) | |
| `0xAA` | Screen orientation | `01 02 03`, drives Auto Pivot |
| `0xCC` | OSD language | 21 codes, English is `0x02` |
| `0xD6` | Power mode | `50 60 90 A0`, BenQ-remapped DPMS states |
| `0xDC` | Picture mode | `0A` sRGB, `0F` M-book, `12` User, `1F`, `22` Display-P3, `23` HDR, `28` Game, `32` Cinema |
| `0xDF` | MCCS version | `0x0202` is 2.2 |

Vendor-specific and not fully identified, listed for completeness: `0x13(00 01)`,
`0x5F(00 02 03)`, `0x67`, `0x68`, `0x69`, `0x6A`, `0x72` (gamma set
`50 64 77 78 8C A0`), `0x81(00 01 02)`, `0x86(01 02 05)`, `0xBE`, `0xC1`, `0xC2`,
`0xC9`, `0xCA`, `0xE5`, `0xEE`, `0xEF`, `0xF0`, `0xF6` (auto input switching),
`0xF8`, `0xFD`. These drive BenQ features such as KVM, PIP/PBP, the brightness
intelligence sensor, ICC Sync, HDR and eco modes.

## Gotchas

Ranked by how much time they cost to discover:

1. **Input read and write values differ.** USB-C reads back `0x13` but that value
   is not in the monitor's advertised settable list. Two maps, not one.
2. **Auto input switching (`0xF6`) silently reverts your input change.** Disable
   it first, then switch.
3. **Switching to a dead input can sever DDC**, because the control channel rides
   the same USB-C link as the picture. Only the physical OSD recovers it.
4. **The advertised input list contains phantoms.** `0x0F` and `0x15` are listed
   but not real on the MA320UP.
5. **Volume max is 50, not 100.** Read the max from the reply; never hardcode.
6. **Reads fail routinely.** Retry with spacing, and validate the frame before
   trusting what you decoded.
7. **DDC/CI can be switched off in the monitor's OSD**, which looks exactly like
   an unsupported display until you tell the user where the setting is.

## Provenance

The protocol details, VCP codes and value ranges were reverse-engineered from
BenQ Display Pilot 2 (v1.12.4.0) by inspecting its linked frameworks and its own
debug logs, then cross-checked against live DDC reads and writes on a BenQ
MA320UP. Every value the implementation depends on is confirmed by at least two
independent sources: the monitor's capabilities string, a live read, and where
applicable the app's own model config.

This project is not affiliated with or endorsed by BenQ.
