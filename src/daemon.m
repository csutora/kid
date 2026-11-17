#import "daemon.h"

#import <AppKit/AppKit.h>
#import <ApplicationServices/ApplicationServices.h>
#import <IOKit/hid/IOHIDProperties.h>
#import <IOKit/hidsystem/IOHIDLib.h>
#import <IOKit/hidsystem/IOHIDEventSystemClient.h>
#import <IOKit/hidsystem/IOHIDParameter.h>
#import <IOKit/hidsystem/IOLLEvent.h>
#include <mach/mach_time.h>
#include <signal.h>
#include <spawn.h>

#import "config.h"
#import "ipc.h"
#import "keyboards.h"

extern char **environ;

typedef enum : uint8_t {
    key_passthrough,
    key_hyper,
    key_layer,
    key_swallowed,
} key_state_t;

static const CGEventFlags hyper_flags =
    kCGEventFlagMaskCommand | kCGEventFlagMaskControl | kCGEventFlagMaskAlternate | kCGEventFlagMaskShift |
    NX_DEVICELCMDKEYMASK | NX_DEVICELCTLKEYMASK | NX_DEVICELALTKEYMASK | NX_DEVICELSHIFTKEYMASK;

static NSString *config_path;
static bool config_optional;
static pinky_config *config;
static pinky_keyboards *keyboards;
static NSString *frontmost_app;
static CFMachPortRef tap;
static IOHIDEventSystemClientRef hid_client;

static key_state_t key_states[128];
static CGKeyCode layer_targets[128];

static bool caps_down;
static bool caps_used;
static uint64_t caps_since;
static CGEventRef caps_event;

static uint64_t elapsed_ms(uint64_t since) {
    static mach_timebase_info_data_t timebase;
    if (!timebase.denom) mach_timebase_info(&timebase);
    return (mach_absolute_time() - since) * timebase.numer / timebase.denom / 1000000;
}

static void remap_caps_lock(void) {
    if (!hid_client) hid_client = IOHIDEventSystemClientCreateSimpleClient(kCFAllocatorDefault);
    NSArray *mapping = @[@{
        @kIOHIDKeyboardModifierMappingSrcKey: @0x700000039,
        @kIOHIDKeyboardModifierMappingDstKey: @0x700000029,
    }];
    if (!IOHIDEventSystemClientSetProperty(hid_client, CFSTR(kIOHIDUserKeyUsageMapKey), (__bridge CFArrayRef)mapping)) {
        fprintf(stderr, "pinky: could not remap caps lock to escape\n");
    }
}

static modifiers_t modifiers_from(CGEventFlags flags, bool hyper) {
    static const struct {
        int mod;
        CGEventFlags generic, left, right;
    } masks[] = {
        {mod_command, kCGEventFlagMaskCommand, NX_DEVICELCMDKEYMASK, NX_DEVICERCMDKEYMASK},
        {mod_option, kCGEventFlagMaskAlternate, NX_DEVICELALTKEYMASK, NX_DEVICERALTKEYMASK},
        {mod_control, kCGEventFlagMaskControl, NX_DEVICELCTLKEYMASK, NX_DEVICERCTLKEYMASK},
        {mod_shift, kCGEventFlagMaskShift, NX_DEVICELSHIFTKEYMASK, NX_DEVICERSHIFTKEYMASK},
    };
    modifiers_t mods = {.hyper = hyper};
    for (size_t i = 0; i < sizeof masks / sizeof *masks; i++) {
        mods.left[masks[i].mod] = flags & masks[i].left;
        mods.right[masks[i].mod] = flags & masks[i].right;
        if ((flags & masks[i].generic) && !mods.left[masks[i].mod] && !mods.right[masks[i].mod]) {
            mods.left[masks[i].mod] = true;
        }
    }
    return mods;
}

static void run(NSString *command) {
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        posix_spawnattr_t attr;
        posix_spawnattr_init(&attr);
        posix_spawnattr_setflags(&attr, POSIX_SPAWN_SETSID | POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_SETSIGMASK |
                                            POSIX_SPAWN_CLOEXEC_DEFAULT);
        sigset_t signals;
        sigemptyset(&signals);
        posix_spawnattr_setsigmask(&attr, &signals);
        sigaddset(&signals, SIGCHLD);
        sigaddset(&signals, SIGPIPE);
        sigaddset(&signals, SIGHUP);
        posix_spawnattr_setsigdefault(&attr, &signals);

        posix_spawn_file_actions_t actions;
        posix_spawn_file_actions_init(&actions);
        posix_spawn_file_actions_addopen(&actions, STDIN_FILENO, "/dev/null", O_RDONLY, 0);
        posix_spawn_file_actions_addinherit_np(&actions, STDOUT_FILENO);
        posix_spawn_file_actions_addinherit_np(&actions, STDERR_FILENO);

        pid_t pid;
        char *argv[] = {"/bin/sh", "-c", (char *)command.UTF8String, NULL};
        int result = posix_spawn(&pid, argv[0], &actions, &attr, argv, environ);
        if (result) fprintf(stderr, "pinky: could not run `%s`: %s\n", command.UTF8String, strerror(result));

        posix_spawn_file_actions_destroy(&actions);
        posix_spawnattr_destroy(&attr);
    });
}

static pinky_binding *find_binding(CGKeyCode code, modifiers_t mods) {
    for (pinky_binding *b in config.bindings) {
        if ([b matches_key:code modifiers:mods app:frontmost_app]) return b;
    }
    return nil;
}

static CGEventRef remap(CGEventRef event, CGKeyCode target, bool down) {
    CGEventSourceRef source = CGEventCreateSourceFromEvent(event);
    CGEventRef out = CGEventCreateKeyboardEvent(source, target, down);
    if (source) CFRelease(source);
    if (!out) return event;
    CGEventFlags flags = CGEventGetFlags(event) & ~(kCGEventFlagMaskSecondaryFn | kCGEventFlagMaskNumericPad);
    CGEventSetFlags(out, flags | key_implicit_flags(target));
    CGEventSetTimestamp(out, CGEventGetTimestamp(event));
    CGEventSetIntegerValueField(out, kCGKeyboardEventAutorepeat,
                                CGEventGetIntegerValueField(event, kCGKeyboardEventAutorepeat));
    CGEventSetIntegerValueField(out, kCGKeyboardEventKeyboardType,
                                CGEventGetIntegerValueField(event, kCGKeyboardEventKeyboardType));
    return out;
}

static CGEventRef caps_released(CGEventTapProxy proxy, CGEventRef event) {
    caps_down = false;
    CGEventRef down = caps_event;
    caps_event = NULL;
    bool tapped = !caps_used && elapsed_ms(caps_since) <= config->tap_timeout_ms;
    if (tapped && down) CGEventTapPostEvent(proxy, down);
    if (down) CFRelease(down);
    return tapped ? event : NULL;
}

static CGEventRef on_event(CGEventTapProxy proxy, CGEventType type, CGEventRef event, void *context) {
    if (type == kCGEventTapDisabledByTimeout || type == kCGEventTapDisabledByUserInput) {
        if (type == kCGEventTapDisabledByTimeout) fprintf(stderr, "pinky: event tap timed out, reenabling\n");
        CGEventTapEnable(tap, true);
        return event;
    }

    if (type != kCGEventKeyDown && type != kCGEventKeyUp) return event;
    CGKeyCode code = (CGKeyCode)CGEventGetIntegerValueField(event, kCGKeyboardEventKeycode);
    if (code >= 128) return event;
    bool down = type == kCGEventKeyDown;
    bool repeat = CGEventGetIntegerValueField(event, kCGKeyboardEventAutorepeat);

    if (code == key_escape) {
        if (down && !caps_down && !repeat && [keyboards caps_held]) {
            caps_down = true;
            caps_used = false;
            caps_since = mach_absolute_time();
            caps_event = CGEventCreateCopy(event);
            return NULL;
        }
        if (down && caps_down && repeat && key_states[code] == key_passthrough) return NULL;
        if (!down && caps_down && ![keyboards caps_held]) return caps_released(proxy, event);
    }

    key_state_t state = key_states[code];
    if (down && !repeat) {
        pinky_binding *binding;
        if (caps_down) caps_used = true;
        if (caps_down && config->layer[code] >= 0) {
            state = key_layer;
            layer_targets[code] = config->layer[code];
        } else if ((binding = find_binding(code, modifiers_from(CGEventGetFlags(event), caps_down)))) {
            state = key_swallowed;
            run(binding.command);
        } else {
            state = caps_down ? key_hyper : key_passthrough;
        }
        key_states[code] = state;
    } else if (!down) {
        key_states[code] = key_passthrough;
    }

    switch (state) {
        case key_passthrough:
            return event;
        case key_hyper:
            CGEventSetFlags(event, CGEventGetFlags(event) | hyper_flags);
            return event;
        case key_layer:
            return remap(event, layer_targets[code], down);
        case key_swallowed:
            return NULL;
    }
    return event;
}

static bool start_tap(void) {
    if (tap) return true;
    CGEventMask mask = CGEventMaskBit(kCGEventKeyDown) | CGEventMaskBit(kCGEventKeyUp);
    tap = CGEventTapCreate(kCGHIDEventTap, kCGHeadInsertEventTap, kCGEventTapOptionDefault, mask, on_event, NULL);
    if (!tap) return false;
    CFRunLoopSourceRef source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0);
    CFRunLoopAddSource(CFRunLoopGetMain(), source, kCFRunLoopCommonModes);
    CFRelease(source);
    return true;
}

static void start(void) {
    static bool prompted_input, prompted_accessibility;
    bool keyboards_ready = [keyboards start] == kIOReturnSuccess;
    if (!keyboards_ready && !prompted_input) {
        prompted_input = true;
        fprintf(stderr, "pinky: waiting for input monitoring permission\n");
        IOHIDRequestAccess(kIOHIDRequestTypeListenEvent);
    }
    bool tap_ready = start_tap();
    if (!tap_ready && !prompted_accessibility) {
        prompted_accessibility = true;
        fprintf(stderr, "pinky: waiting for accessibility permission\n");
        AXIsProcessTrustedWithOptions((__bridge CFDictionaryRef) @{(__bridge NSString *)kAXTrustedCheckOptionPrompt: @YES});
    }
    if (keyboards_ready && tap_ready) {
        fprintf(stderr, "pinky: running\n");
        return;
    }
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 2 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
        start();
    });
}

static NSString *led_status(void) {
    static NSString *const names[] = {[led_auto] = @"auto", [led_on] = @"on", [led_off] = @"off"};
    return [NSString stringWithFormat:@"{\"override\":\"%@\",\"state\":\"%@\"}", names[keyboards.led_override],
                                      keyboards.led_state ? @"on" : @"off"];
}

static NSString *handle(NSString *request) {
    NSArray<NSString *> *words = [request componentsSeparatedByString:@" "];
    if (![words.firstObject isEqualToString:@"led"] || words.count > 2) {
        return @"{\"error\":\"unknown request\"}";
    }
    if (words.count == 2) {
        NSDictionary *overrides = @{@"auto": @(led_auto), @"on": @(led_on), @"off": @(led_off)};
        NSNumber *value = overrides[words[1]];
        if (!value) return @"{\"error\":\"unknown led state, expected on, off, or auto\"}";
        keyboards.led_override = value.intValue;
    }
    return led_status();
}

static void reload(void) {
    NSString *error;
    pinky_config *next = [pinky_config load:config_path optional:config_optional error:&error];
    if (!next) {
        fprintf(stderr, "pinky: keeping the previous config, %s\n", error.UTF8String);
        return;
    }
    config = next;
    fprintf(stderr, "pinky: config reloaded\n");
}

int daemon_main(NSString *path, bool optional) {
    signal(SIGPIPE, SIG_IGN);
    signal(SIGCHLD, SIG_IGN);
    signal(SIGHUP, SIG_IGN);

    config_path = path;
    config_optional = optional;
    NSString *error;
    config = [pinky_config load:config_path optional:config_optional error:&error];
    if (!config) {
        fprintf(stderr, "pinky: %s\n", error.UTF8String);
        return 1;
    }

    remap_caps_lock();

    keyboards = [pinky_keyboards new];
    keyboards.on_added = ^{
        remap_caps_lock();
    };

    if (!ipc_serve(^(NSString *request) { return handle(request); })) {
        fprintf(stderr, "pinky: could not listen on %s: %s\n", ipc_socket_path().UTF8String, strerror(errno));
        return 1;
    }

    dispatch_source_t hangup = dispatch_source_create(DISPATCH_SOURCE_TYPE_SIGNAL, SIGHUP, 0, dispatch_get_main_queue());
    dispatch_source_set_event_handler(hangup, ^{
        reload();
    });
    dispatch_resume(hangup);

    NSNotificationCenter *center = NSWorkspace.sharedWorkspace.notificationCenter;
    frontmost_app = NSWorkspace.sharedWorkspace.frontmostApplication.bundleIdentifier;
    [center addObserverForName:NSWorkspaceDidActivateApplicationNotification
                        object:nil
                         queue:NSOperationQueue.mainQueue
                    usingBlock:^(NSNotification *note) {
                        frontmost_app = [note.userInfo[NSWorkspaceApplicationKey] bundleIdentifier];
                    }];
    [center addObserverForName:NSWorkspaceDidWakeNotification
                        object:nil
                         queue:NSOperationQueue.mainQueue
                    usingBlock:^(NSNotification *note) {
                        remap_caps_lock();
                        [keyboards apply_led];
                    }];

    start();
    CFRunLoopRun();
    return 0;
}
