#include <CoreGraphics/CoreGraphics.h>

static inline CFDataRef _Nullable StudioCopyEventData(CGEventRef _Nonnull event) CF_RETURNS_RETAINED {
    return CGEventCreateData(NULL, event);
}

static inline CGEventRef _Nullable StudioCreateEvent(CFDataRef _Nonnull data) CF_RETURNS_RETAINED {
    return CGEventCreateFromData(NULL, data);
}

CFTypeRef _Nullable StudioCreateVirtualDisplay(uint32_t width, uint32_t height,
                                               CGDirectDisplayID *_Nonnull displayID) CF_RETURNS_RETAINED;
