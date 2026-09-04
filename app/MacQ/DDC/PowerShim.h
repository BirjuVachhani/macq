//
//  PowerShim.h
//  MacQ
//
//  Thin Objective-C boundary around the private display connect/disconnect
//  call, mirroring how DDCShim isolates IOAVService. Swift sees a clean class.
//

#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>

NS_ASSUME_NONNULL_BEGIN

/// Soft "replug" of a display: disconnects and reconnects it the way unplugging
/// the cable would, forcing a full link renegotiation. The reconnect re-drives
/// the video signal, and a signal transition is what BenQ panels wake on, which
/// makes this the last-resort wake path when the panel's DDC is unreachable.
///
/// Built on `CGSConfigureDisplayEnabled`, a private call exported by
/// CoreGraphics (a re-export of SkyLight's `SLSConfigureDisplayEnabled`,
/// present in SDK stubs since macOS 11). The same mechanism the open-source
/// LightsOut app ships with, and behaviorally what Lunar's and BetterDisplay's
/// disconnect features do on Apple Silicon.
@interface DisplayReplug : NSObject

/// Applies one enable/disable transaction to the display. Returns NO if any
/// step of the configuration transaction failed (the transaction is cancelled,
/// nothing is left half-applied).
///
/// The transaction is completed with `kCGConfigureForAppOnly`, so a disable
/// dies with the process: a crashed or quit MacQ cannot leave the display
/// disconnected.
+ (BOOL)setDisplay:(CGDirectDisplayID)displayID enabled:(BOOL)enabled
    NS_SWIFT_NAME(setDisplay(_:enabled:));

/// Global undo: restores the user's saved permanent display configuration.
/// Used when a disable succeeded but the matching enable failed.
+ (void)restorePermanentConfiguration;

@end

NS_ASSUME_NONNULL_END
