#import "keyboards.h"

#import <CoreGraphics/CoreGraphics.h>
#import <IOKit/hid/IOHIDManager.h>
#include <mach/mach_time.h>

@interface pinky_keyboard : NSObject {
@public
    IOHIDDeviceRef device;
    IOHIDElementRef caps;
    IOHIDElementRef led;
}
@end

@implementation pinky_keyboard

- (void)dealloc {
    if (caps) CFRelease(caps);
    if (led) CFRelease(led);
    CFRelease(device);
}

@end

@implementation pinky_keyboards {
    IOHIDManagerRef manager;
    NSMutableArray<pinky_keyboard *> *keyboards;
}

static void matched(void *context, IOReturn result, void *sender, IOHIDDeviceRef device) {
    [(__bridge pinky_keyboards *)context add:device];
}

static void removed(void *context, IOReturn result, void *sender, IOHIDDeviceRef device) {
    [(__bridge pinky_keyboards *)context remove:device];
}

- (instancetype)init {
    if ((self = [super init])) {
        keyboards = [NSMutableArray array];
    }
    return self;
}

- (IOReturn)start {
    if (manager) return kIOReturnSuccess;
    IOHIDManagerRef m = IOHIDManagerCreate(kCFAllocatorDefault, kIOHIDOptionsTypeNone);
    IOHIDManagerSetDeviceMatching(m, (__bridge CFDictionaryRef) @{
        @kIOHIDDeviceUsagePageKey: @(kHIDPage_GenericDesktop),
        @kIOHIDDeviceUsageKey: @(kHIDUsage_GD_Keyboard),
    });
    IOHIDManagerRegisterDeviceMatchingCallback(m, matched, (__bridge void *)self);
    IOHIDManagerRegisterDeviceRemovalCallback(m, removed, (__bridge void *)self);
    IOHIDManagerScheduleWithRunLoop(m, CFRunLoopGetMain(), kCFRunLoopDefaultMode);
    IOReturn result = IOHIDManagerOpen(m, kIOHIDOptionsTypeNone);
    if (result != kIOReturnSuccess) {
        IOHIDManagerUnscheduleFromRunLoop(m, CFRunLoopGetMain(), kCFRunLoopDefaultMode);
        CFRelease(m);
        return result;
    }
    manager = m;
    return result;
}

- (void)add:(IOHIDDeviceRef)device {
    pinky_keyboard *k = [pinky_keyboard new];
    k->device = (IOHIDDeviceRef)CFRetain(device);
    CFArrayRef elements = IOHIDDeviceCopyMatchingElements(device, NULL, kIOHIDOptionsTypeNone);
    for (CFIndex i = 0; elements && i < CFArrayGetCount(elements); i++) {
        IOHIDElementRef e = (IOHIDElementRef)CFArrayGetValueAtIndex(elements, i);
        uint32_t page = IOHIDElementGetUsagePage(e), usage = IOHIDElementGetUsage(e);
        if (!k->caps && page == kHIDPage_KeyboardOrKeypad && usage == kHIDUsage_KeyboardCapsLock &&
            IOHIDElementGetType(e) != kIOHIDElementTypeOutput) {
            k->caps = (IOHIDElementRef)CFRetain(e);
        } else if (!k->led && page == kHIDPage_LEDs && usage == kHIDUsage_LED_CapsLock &&
                   IOHIDElementGetType(e) == kIOHIDElementTypeOutput) {
            k->led = (IOHIDElementRef)CFRetain(e);
        }
    }
    if (elements) CFRelease(elements);
    if (!k->caps && !k->led) return;
    [keyboards addObject:k];
    [self apply_led_to:k];
    if (self.on_added) self.on_added();
}

- (void)remove:(IOHIDDeviceRef)device {
    for (NSUInteger i = 0; i < keyboards.count; i++) {
        if (CFEqual(keyboards[i]->device, device)) {
            [keyboards removeObjectAtIndex:i];
            return;
        }
    }
}

- (bool)caps_held {
    for (pinky_keyboard *k in keyboards) {
        IOHIDValueRef value;
        if (k->caps && IOHIDDeviceGetValue(k->device, k->caps, &value) == kIOReturnSuccess &&
            IOHIDValueGetIntegerValue(value)) {
            return true;
        }
    }
    return false;
}

- (bool)led_state {
    switch (self.led_override) {
        case led_on: return true;
        case led_off: return false;
        case led_auto: return CGEventSourceFlagsState(kCGEventSourceStateHIDSystemState) & kCGEventFlagMaskAlphaShift;
    }
    return false;
}

- (void)setLed_override:(led_override_t)led_override {
    _led_override = led_override;
    [self apply_led];
}

- (void)apply_led {
    for (pinky_keyboard *k in keyboards) [self apply_led_to:k];
}

- (void)apply_led_to:(pinky_keyboard *)k {
    if (!k->led) return;
    CFIndex x = self.led_state ? IOHIDElementGetLogicalMax(k->led) : IOHIDElementGetLogicalMin(k->led);
    IOHIDValueRef value = IOHIDValueCreateWithIntegerValue(kCFAllocatorDefault, k->led, mach_absolute_time(), x);
    IOReturn result = IOHIDDeviceSetValue(k->device, k->led, value);
    CFRelease(value);
    if (result != kIOReturnSuccess) {
        NSString *name = (__bridge NSString *)IOHIDDeviceGetProperty(k->device, CFSTR(kIOHIDProductKey));
        fprintf(stderr, "pinky: could not set the caps lock led of %s: 0x%x\n", name.UTF8String ?: "a keyboard", result);
    }
}

@end
