#import <Foundation/Foundation.h>
#import "ReceiverEvents.h"

// Resolve WindowServer's virtual-display objects at runtime. This API is
// optional, so the receiver and the regular capture presets do not depend on it.
@protocol StudioDisplayDescriptor
@property(nonatomic, strong) dispatch_queue_t queue;
@property(nonatomic, copy) NSString *name;
@property(nonatomic) CGPoint whitePoint;
@property(nonatomic) CGPoint redPrimary;
@property(nonatomic) CGPoint greenPrimary;
@property(nonatomic) CGPoint bluePrimary;
@property(nonatomic) CGSize sizeInMillimeters;
@property(nonatomic) unsigned int maxPixelsWide;
@property(nonatomic) unsigned int maxPixelsHigh;
@property(nonatomic) unsigned int vendorID;
@property(nonatomic) unsigned int productID;
@property(nonatomic) unsigned int serialNum;
@property(nonatomic) unsigned int serialNumber;
@end

@protocol StudioDisplaySettings
@property(nonatomic) unsigned int hiDPI;
@property(nonatomic, copy) NSArray *modes;
@end

@protocol StudioDisplayMode
- (instancetype)initWithWidth:(unsigned int)width height:(unsigned int)height refreshRate:(double)rate;
@end

@protocol StudioDisplay
- (instancetype)initWithDescriptor:(id<StudioDisplayDescriptor>)descriptor;
- (BOOL)applySettings:(id<StudioDisplaySettings>)settings;
@property(nonatomic, readonly) CGDirectDisplayID displayID;
@end

CFTypeRef StudioCreateVirtualDisplay(uint32_t width, uint32_t height, CGDirectDisplayID *displayID) {
    Class descriptorClass = NSClassFromString(@"CGVirtualDisplayDescriptor");
    Class settingsClass = NSClassFromString(@"CGVirtualDisplaySettings");
    Class modeClass = NSClassFromString(@"CGVirtualDisplayMode");
    Class displayClass = NSClassFromString(@"CGVirtualDisplay");
    if (!descriptorClass || !settingsClass || !modeClass || !displayClass) return NULL;

    id<StudioDisplayDescriptor> descriptor = [descriptorClass new];
    id<StudioDisplaySettings> settings = [settingsClass new];
    if (!descriptor || !settings) return NULL;
    descriptor.queue = dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0);
    descriptor.name = @"파이널 퓨전 픽셀 맞춤";
    descriptor.whitePoint = CGPointMake(0.3127, 0.3290);
    descriptor.redPrimary = CGPointMake(0.640, 0.330);
    descriptor.greenPrimary = CGPointMake(0.300, 0.600);
    descriptor.bluePrimary = CGPointMake(0.150, 0.060);
    descriptor.maxPixelsWide = width;
    descriptor.maxPixelsHigh = height;
    descriptor.sizeInMillimeters = CGSizeMake(width * 25.4 / 220, height * 25.4 / 220);
    descriptor.vendorID = 0x5352;
    descriptor.productID = 1;
    unsigned int serial = arc4random_uniform(UINT32_MAX - 1) + 1;
    descriptor.serialNum = serial;
    if ([(id)descriptor respondsToSelector:@selector(setSerialNumber:)]) descriptor.serialNumber = serial;

    id<StudioDisplayMode> mode = [(id<StudioDisplayMode>)[modeClass alloc] initWithWidth:width / 2
                                                                                height:height / 2
                                                                           refreshRate:60];
    if (!mode) return NULL;
    settings.hiDPI = 1;
    settings.modes = @[mode];

    id<StudioDisplay> display = [(id<StudioDisplay>)[displayClass alloc] initWithDescriptor:descriptor];
    if (!display || ![display applySettings:settings] || !display.displayID) return NULL;
    *displayID = display.displayID;
    return (__bridge_retained CFTypeRef)display;
}
