//
//  DDCShim.h
//  MacQ
//
//  Thin Objective-C boundary around the private IOKit/CoreDisplay APIs used for
//  DDC/CI on Apple Silicon. Keeping IOAVService + CoreFoundation ownership here
//  (where ARC handles it naturally) avoids Unmanaged/CF-bridging friction in
//  Swift. Swift only ever sees clean primitives via DDCLink.
//
//  The DDC transport was reverse-engineered from BenQ Display Pilot 2 and
//  validated against a live BenQ MA320UP. See /docs/benq-ddc-reference.md.
//

#import <Foundation/Foundation.h>
#import <IOKit/IOKitLib.h>
#import <CoreGraphics/CoreGraphics.h>

NS_ASSUME_NONNULL_BEGIN

/// A bound DDC/CI transport for one external display's I2C channel.
///
/// Wraps a private `IOAVServiceRef` resolved from the display's
/// `DCPAVServiceProxy` in the IORegistry. Use `writeI2C:length:` /
/// `readI2C:length:` to exchange raw DDC/CI frames; the framing, checksums, and
/// retry policy live in Swift (`DDC.swift`).
@interface DDCLink : NSObject

/// Resolves the external AV service for the given display and returns a bound
/// link, or `nil` if the display has no reachable external DDC channel (for
/// example the built-in panel, or a display behind an adapter that blocks I2C).
+ (nullable instancetype)linkForDisplayID:(CGDirectDisplayID)displayID
    NS_SWIFT_NAME(make(displayID:));

/// The DDC/CI I2C chip address (0x37 normally, 0xB7 for MCDP29xx bridges).
@property (nonatomic, readonly) uint32_t chipAddress;

/// Writes a raw DDC/CI frame. Returns `kIOReturnSuccess` (0) on success.
- (int)writeI2C:(const uint8_t *)bytes length:(uint32_t)length;

/// Reads a raw DDC/CI reply into `buffer`. Returns `kIOReturnSuccess` (0) on success.
- (int)readI2C:(uint8_t *)buffer length:(uint32_t)length;

@end

/// Display identity read straight from the IORegistry, for joining a display to
/// other subsystems that key on the same value.
@interface DisplayIdentity : NSObject

/// The display's `EDID UUID` string, for example
/// `09D13581-0000-0000-2E23-0104B5462778`, or `nil` when the node does not
/// publish one (some adapters, KVMs and virtual displays).
///
/// This is the exact string CoreAudio reports as a DisplayPort/HDMI audio
/// device's `kAudioDevicePropertyDeviceUID`, which makes it an exact join
/// between a display and its audio endpoint rather than a heuristic.
///
/// Note it is NOT the raw EDID bytes 8...23: bytes 12...15 (the binary serial
/// number) are zeroed, which is why two units of the same model bought in the
/// same week can share one. Good enough to answer "is this monitor the current
/// sound output", not a unique per-unit key.
+ (nullable NSString *)edidUUIDForDisplayID:(CGDirectDisplayID)displayID
    NS_SWIFT_NAME(edidUUID(displayID:));

@end

NS_ASSUME_NONNULL_END
