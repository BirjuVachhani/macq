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

NS_ASSUME_NONNULL_END
