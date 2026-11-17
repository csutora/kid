#pragma once

#import <Foundation/Foundation.h>
#include "keys.h"

typedef enum : uint8_t {
    side_none,
    side_any,
    side_left,
    side_right,
    side_both,
} side_t;

enum {
    mod_command,
    mod_option,
    mod_control,
    mod_shift,
    mod_count,
};

typedef struct {
    bool hyper;
    bool left[mod_count];
    bool right[mod_count];
} modifiers_t;

@interface pinky_binding : NSObject {
@public
    CGKeyCode key;
    bool hyper;
    side_t sides[mod_count];
}
@property(copy) NSString *command;
@property(copy) NSSet<NSString *> *unless_apps;
- (bool)matches_key:(CGKeyCode)code modifiers:(modifiers_t)mods app:(NSString *)app;
@end

@interface pinky_config : NSObject {
@public
    uint64_t tap_timeout_ms;
    int layer[128];
}
@property(copy) NSArray<pinky_binding *> *bindings;
+ (NSString *)default_path;
+ (instancetype)load:(NSString *)path optional:(bool)optional error:(NSString **)error;
@end
