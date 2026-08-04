//
//  DDCShim.m
//  MacQ
//
//  Port of the m1ddc IORegistry enumeration + IOAVService I2C transport,
//  keyed by CGDirectDisplayID. Reference: the m1ddc project (github.com/waydabber/m1ddc).
//

#import "DDCShim.h"

// --- Private symbols (resolve from IOKit / CoreDisplay at load time) ---------

typedef CFTypeRef IOAVServiceRef;

extern IOAVServiceRef IOAVServiceCreateWithService(CFAllocatorRef allocator, io_service_t service);
extern IOReturn IOAVServiceReadI2C(IOAVServiceRef service, uint32_t chipAddress,
                                   uint32_t offset, void *outputBuffer, uint32_t outputBufferSize);
extern IOReturn IOAVServiceWriteI2C(IOAVServiceRef service, uint32_t chipAddress,
                                    uint32_t dataAddress, void *inputBuffer, uint32_t inputBufferSize);
extern CFDictionaryRef CoreDisplay_DisplayCreateInfoDictionary(CGDirectDisplayID display);

// --- Constants ---------------------------------------------------------------

static const uint32_t kDDCChipDefault = 0x37;   // DDC/CI host-to-display I2C address
static const uint32_t kDDCChipMCDP29XX = 0xB7;  // MCDP29xx bridge routes DDC here
static const uint32_t kDDCSubAddress = 0x51;    // DDC/CI "offset" for the frame

// --- Helpers -----------------------------------------------------------------

static CFTypeRef CopySearchProperty(io_service_t service, CFStringRef key) {
    return IORegistryEntrySearchCFProperty(service, kIOServicePlane, key,
                                           kCFAllocatorDefault, kIORegistryIterateRecursively);
}

static Boolean IsMCDP29XXProxy(io_service_t proxy) {
    io_registry_entry_t parent = MACH_PORT_NULL;
    if (IORegistryEntryGetParentEntry(proxy, kIOServicePlane, &parent) != KERN_SUCCESS) {
        return false;
    }
    Boolean result = false;
    CFTypeRef providerClass = IORegistryEntryCreateCFProperty(parent, CFSTR("EPICProviderClass"),
                                                              kCFAllocatorDefault, 0);
    if (providerClass != NULL && CFGetTypeID(providerClass) == CFStringGetTypeID()) {
        result = CFStringCompare(providerClass, CFSTR("AppleDCPMCDP29XX"), 0) == kCFCompareEqualTo;
    }
    if (providerClass != NULL) CFRelease(providerClass);
    IOObjectRelease(parent);
    return result;
}

// Resolves the IORegistry adapter node for a display via its IODisplayLocation.
static io_service_t CopyAdapterForDisplay(CGDirectDisplayID displayID) {
    CFDictionaryRef info = CoreDisplay_DisplayCreateInfoDictionary(displayID);
    if (info == NULL) return MACH_PORT_NULL;

    io_service_t adapter = MACH_PORT_NULL;
    CFStringRef ioLocation = CFDictionaryGetValue(info, CFSTR("IODisplayLocation"));
    if (ioLocation != NULL && CFGetTypeID(ioLocation) == CFStringGetTypeID()) {
        adapter = IORegistryEntryCopyFromPath(kIOMainPortDefault, ioLocation);
    }
    CFRelease(info);
    return adapter;
}

// --- DDCLink -----------------------------------------------------------------

@implementation DDCLink {
    IOAVServiceRef _service;
}

+ (nullable instancetype)linkForDisplayID:(CGDirectDisplayID)displayID {
    io_service_t adapter = CopyAdapterForDisplay(displayID);
    if (adapter == MACH_PORT_NULL) return nil;

    uint64_t adapterEntryID = 0;
    if (IORegistryEntryGetRegistryEntryID(adapter, &adapterEntryID) != KERN_SUCCESS) {
        IOObjectRelease(adapter);
        return nil;
    }
    IOObjectRelease(adapter);

    io_registry_entry_t root = IORegistryGetRootEntry(kIOMainPortDefault);
    io_iterator_t iter = MACH_PORT_NULL;
    kern_return_t iterResult = IORegistryEntryCreateIterator(root, kIOServicePlane,
                                                             kIORegistryIterateRecursively, &iter);
    IOObjectRelease(root); // root is only needed to seed the iterator
    if (iterResult != KERN_SUCCESS) {
        return nil;
    }

    DDCLink *link = nil;
    Boolean framebufferMatches = false;
    io_service_t service = MACH_PORT_NULL;

    while ((service = IOIteratorNext(iter)) != MACH_PORT_NULL) {
        if (IOObjectConformsTo(service, "IOMobileFramebuffer")) {
            uint64_t fbID = 0;
            framebufferMatches =
                IORegistryEntryGetRegistryEntryID(service, &fbID) == KERN_SUCCESS &&
                fbID == adapterEntryID;
            IOObjectRelease(service);
            continue;
        }

        io_name_t name;
        IORegistryEntryGetName(service, name);
        if (!framebufferMatches || strcmp(name, "DCPAVServiceProxy") != 0) {
            IOObjectRelease(service);
            continue;
        }

        IOAVServiceRef avService = IOAVServiceCreateWithService(kCFAllocatorDefault, service);
        if (avService == NULL) {
            IOObjectRelease(service);
            continue;
        }

        CFTypeRef location = CopySearchProperty(service, CFSTR("Location"));
        Boolean isExternal = location != NULL &&
            CFGetTypeID(location) == CFStringGetTypeID() &&
            CFStringCompare(CFSTR("External"), location, 0) == kCFCompareEqualTo;
        if (location != NULL) CFRelease(location);

        if (!isExternal) {
            CFRelease(avService);
            IOObjectRelease(service);
            continue;
        }

        link = [[DDCLink alloc] init];
        link->_service = avService; // takes ownership (+1 from Create)
        link->_chipAddress = IsMCDP29XXProxy(service) ? kDDCChipMCDP29XX : kDDCChipDefault;
        IOObjectRelease(service);
        break;
    }

    IOObjectRelease(iter);
    return link;
}

- (int)writeI2C:(const uint8_t *)bytes length:(uint32_t)length {
    if (_service == NULL) return kIOReturnNotOpen;
    return IOAVServiceWriteI2C(_service, _chipAddress, kDDCSubAddress, (void *)bytes, length);
}

- (int)readI2C:(uint8_t *)buffer length:(uint32_t)length {
    if (_service == NULL) return kIOReturnNotOpen;
    return IOAVServiceReadI2C(_service, _chipAddress, kDDCSubAddress, buffer, length);
}

- (void)dealloc {
    if (_service != NULL) {
        CFRelease(_service);
        _service = NULL;
    }
}

@end
