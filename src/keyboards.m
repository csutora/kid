#import "keyboards.h"

#import <CoreGraphics/CoreGraphics.h>
#import <IOKit/hid/IOHIDManager.h>
#import <IOKit/hidsystem/IOLLEvent.h>
#include <mach/mach_time.h>

@interface kid_keyboard : NSObject {
@public
    IOHIDDeviceRef device;
    IOHIDElementRef caps;
    IOHIDElementRef led;
    IOHIDElementRef modifiers[8];
}
@end

@implementation kid_keyboard

- (void)dealloc {
    if (caps) CFRelease(caps);
    if (led) CFRelease(led);
    for (int i = 0; i < 8; i++) {
        if (modifiers[i]) CFRelease(modifiers[i]);
    }
    CFRelease(device);
}

@end

static const CGEventFlags modifier_flags[8] = {
    kCGEventFlagMaskControl | NX_DEVICELCTLKEYMASK,
    kCGEventFlagMaskShift | NX_DEVICELSHIFTKEYMASK,
    kCGEventFlagMaskAlternate | NX_DEVICELALTKEYMASK,
    kCGEventFlagMaskCommand | NX_DEVICELCMDKEYMASK,
    kCGEventFlagMaskControl | NX_DEVICERCTLKEYMASK,
    kCGEventFlagMaskShift | NX_DEVICERSHIFTKEYMASK,
    kCGEventFlagMaskAlternate | NX_DEVICERALTKEYMASK,
    kCGEventFlagMaskCommand | NX_DEVICERCMDKEYMASK,
};

@implementation kid_keyboards {
    IOHIDManagerRef manager;
    NSMutableArray<kid_keyboard *> *keyboards;
    uint64_t flash_generation;
    bool flashing;
    bool flash_lit;
}

static void matched(void *context, IOReturn result, void *sender, IOHIDDeviceRef device) {
    [(__bridge kid_keyboards *)context add:device];
}

static void removed(void *context, IOReturn result, void *sender, IOHIDDeviceRef device) {
    [(__bridge kid_keyboards *)context remove:device];
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
    kid_keyboard *k = [kid_keyboard new];
    k->device = (IOHIDDeviceRef)CFRetain(device);
    CFArrayRef elements = IOHIDDeviceCopyMatchingElements(device, NULL, kIOHIDOptionsTypeNone);
    for (CFIndex i = 0; elements && i < CFArrayGetCount(elements); i++) {
        IOHIDElementRef e = (IOHIDElementRef)CFArrayGetValueAtIndex(elements, i);
        uint32_t page = IOHIDElementGetUsagePage(e), usage = IOHIDElementGetUsage(e);
        if (!k->caps && page == kHIDPage_KeyboardOrKeypad && usage == kHIDUsage_KeyboardCapsLock &&
            IOHIDElementGetType(e) != kIOHIDElementTypeOutput) {
            k->caps = (IOHIDElementRef)CFRetain(e);
        } else if (page == kHIDPage_KeyboardOrKeypad && usage >= kHIDUsage_KeyboardLeftControl &&
                   usage <= kHIDUsage_KeyboardRightGUI && IOHIDElementGetType(e) != kIOHIDElementTypeOutput &&
                   !k->modifiers[usage - kHIDUsage_KeyboardLeftControl]) {
            k->modifiers[usage - kHIDUsage_KeyboardLeftControl] = (IOHIDElementRef)CFRetain(e);
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
    for (kid_keyboard *k in keyboards) {
        IOHIDValueRef value;
        if (k->caps && IOHIDDeviceGetValue(k->device, k->caps, &value) == kIOReturnSuccess &&
            IOHIDValueGetIntegerValue(value)) {
            return true;
        }
    }
    return false;
}

- (CGEventFlags)held_modifiers {
    CGEventFlags flags = 0;
    for (kid_keyboard *k in keyboards) {
        for (int i = 0; i < 8; i++) {
            IOHIDValueRef value;
            if (k->modifiers[i] && IOHIDDeviceGetValue(k->device, k->modifiers[i], &value) == kIOReturnSuccess &&
                IOHIDValueGetIntegerValue(value)) {
                flags |= modifier_flags[i];
            }
        }
    }
    return flags;
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

- (void)flash:(unsigned)times interval_ms:(double)interval {
    uint64_t generation = ++flash_generation;
    bool base = self.led_state;
    flashing = true;
    [self flash_step:0 of:times * 2 base:base interval_ms:interval generation:generation];
}

- (void)flash_step:(unsigned)step of:(unsigned)steps base:(bool)base interval_ms:(double)interval generation:(uint64_t)generation {
    if (generation != flash_generation) return;
    if (step == steps) {
        flashing = false;
        [self apply_led];
        return;
    }
    flash_lit = step % 2 ? base : !base;
    [self apply_led];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(interval * NSEC_PER_MSEC)), dispatch_get_main_queue(), ^{
        [self flash_step:step + 1 of:steps base:base interval_ms:interval generation:generation];
    });
}

- (void)apply_led {
    for (kid_keyboard *k in keyboards) [self apply_led_to:k];
}

- (void)apply_led_to:(kid_keyboard *)k {
    if (!k->led) return;
    bool lit = flashing ? flash_lit : self.led_state;
    CFIndex x = lit ? IOHIDElementGetLogicalMax(k->led) : IOHIDElementGetLogicalMin(k->led);
    IOHIDValueRef value = IOHIDValueCreateWithIntegerValue(kCFAllocatorDefault, k->led, mach_absolute_time(), x);
    IOReturn result = IOHIDDeviceSetValue(k->device, k->led, value);
    CFRelease(value);
    if (result != kIOReturnSuccess) {
        NSString *name = (__bridge NSString *)IOHIDDeviceGetProperty(k->device, CFSTR(kIOHIDProductKey));
        fprintf(stderr, "kid: could not set the caps lock led of %s: 0x%x\n", name.UTF8String ?: "a keyboard", result);
    }
}

@end
