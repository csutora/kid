#pragma once

#import <Foundation/Foundation.h>

typedef enum {
    led_auto,
    led_on,
    led_off,
} led_override_t;

@interface pinky_keyboards : NSObject
@property(nonatomic) led_override_t led_override;
@property(copy) void (^on_added)(void);
- (IOReturn)start;
- (bool)caps_held;
- (bool)led_state;
- (void)apply_led;
- (void)flash:(unsigned)times interval_ms:(double)interval;
@end
