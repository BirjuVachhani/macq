//
//  PowerShim.m
//  MacQ
//

#import "PowerShim.h"

// --- Private symbol (resolves from CoreGraphics at load time; CoreGraphics
// re-exports SkyLight's _SLSConfigureDisplayEnabled under this name) ----------
extern CGError CGSConfigureDisplayEnabled(CGDisplayConfigRef config,
                                          CGDirectDisplayID display,
                                          bool enabled);

@implementation DisplayReplug

+ (BOOL)setDisplay:(CGDirectDisplayID)displayID enabled:(BOOL)enabled {
    CGDisplayConfigRef config = NULL;
    CGError err = CGBeginDisplayConfiguration(&config);
    if (err != kCGErrorSuccess || config == NULL) {
        NSLog(@"MacQ.replug: CGBeginDisplayConfiguration failed (%d)", err);
        return NO;
    }

    err = CGSConfigureDisplayEnabled(config, displayID, enabled);
    if (err != kCGErrorSuccess) {
        NSLog(@"MacQ.replug: CGSConfigureDisplayEnabled(%u, %d) failed (%d)",
              displayID, enabled, err);
        CGCancelDisplayConfiguration(config);
        return NO;
    }

    // kCGConfigureForAppOnly: the change is scoped to this process's lifetime,
    // so a disable can never outlive MacQ.
    err = CGCompleteDisplayConfiguration(config, kCGConfigureForAppOnly);
    if (err != kCGErrorSuccess) {
        NSLog(@"MacQ.replug: CGCompleteDisplayConfiguration failed (%d)", err);
        return NO;
    }

    NSLog(@"MacQ.replug: display %u %@", displayID, enabled ? @"enabled" : @"disabled");
    return YES;
}

+ (void)restorePermanentConfiguration {
    NSLog(@"MacQ.replug: restoring permanent display configuration");
    CGRestorePermanentDisplayConfiguration();
}

@end
