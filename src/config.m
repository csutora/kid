#import "config.h"

static const struct {
    const char *name;
    int mod;
    side_t side;
} modifier_names[] = {
    {"command", mod_command, side_any},
    {"left_command", mod_command, side_left},
    {"right_command", mod_command, side_right},
    {"option", mod_option, side_any},
    {"left_option", mod_option, side_left},
    {"right_option", mod_option, side_right},
    {"control", mod_control, side_any},
    {"left_control", mod_control, side_left},
    {"right_control", mod_control, side_right},
    {"shift", mod_shift, side_any},
    {"left_shift", mod_shift, side_left},
    {"right_shift", mod_shift, side_right},
};

static bool side_matches(side_t side, bool left, bool right) {
    switch (side) {
        case side_none: return !left && !right;
        case side_any: return left || right;
        case side_left: return left && !right;
        case side_right: return right && !left;
        case side_both: return left && right;
    }
    return false;
}

static side_t side_merge(side_t a, side_t b) {
    if (a == side_none) return b;
    if (a == b) return a;
    if (a == side_any || b == side_any) return side_any;
    return side_both;
}

@implementation kid_binding

- (bool)matches_key:(CGKeyCode)code modifiers:(modifiers_t)mods app:(NSString *)app {
    if (code != key || mods.hyper != hyper) return false;
    for (int m = 0; m < mod_count; m++) {
        if (!side_matches(sides[m], mods.left[m], mods.right[m])) return false;
    }
    return !app || ![self.unless_apps containsObject:app];
}

@end

@implementation kid_config

+ (NSString *)default_path {
    return [NSHomeDirectory() stringByAppendingPathComponent:@".config/kid/config.json"];
}

static id fail(NSString **error, NSString *format, ...) NS_FORMAT_FUNCTION(2, 3);
static id fail(NSString **error, NSString *format, ...) {
    va_list args;
    va_start(args, format);
    *error = [[NSString alloc] initWithFormat:format arguments:args];
    va_end(args);
    return nil;
}

static bool parse_key(id value, CGKeyCode *code) {
    return [value isKindOfClass:NSString.class] && key_from_name([value UTF8String], code);
}

- (instancetype)init {
    if ((self = [super init])) {
        tap_timeout_ms = 1000;
        for (int i = 0; i < 128; i++) layer[i] = -1;
        _bindings = @[];
    }
    return self;
}

+ (instancetype)load:(NSString *)path optional:(bool)optional error:(NSString **)error {
    kid_config *config = [kid_config new];
    NSData *data = [NSData dataWithContentsOfFile:path];
    if (!data) {
        if (optional && ![NSFileManager.defaultManager fileExistsAtPath:path]) return config;
        return fail(error, @"%@: could not read file", path);
    }

    NSError *json_error;
    id root = [NSJSONSerialization JSONObjectWithData:data options:0 error:&json_error];
    if (!root) return fail(error, @"%@: %@", path, json_error.userInfo[NSDebugDescriptionErrorKey] ?: json_error.localizedDescription);
    if (![root isKindOfClass:NSDictionary.class]) return fail(error, @"%@: expected an object", path);

    for (NSString *field in root) {
        if (![@[@"tap_timeout_ms", @"layer", @"bindings"] containsObject:field]) {
            return fail(error, @"unknown field `%@`", field);
        }
    }

    id timeout = root[@"tap_timeout_ms"];
    if (timeout) {
        if (![timeout isKindOfClass:NSNumber.class] || [timeout doubleValue] < 0 ||
            [timeout doubleValue] != [timeout unsignedLongLongValue]) {
            return fail(error, @"tap_timeout_ms: expected a non-negative integer");
        }
        config->tap_timeout_ms = [timeout unsignedLongLongValue];
    }

    id layer = root[@"layer"];
    if (layer) {
        if (![layer isKindOfClass:NSDictionary.class]) return fail(error, @"layer: expected an object");
        for (NSString *from in layer) {
            CGKeyCode f, t;
            if (!key_from_name(from.UTF8String, &f)) return fail(error, @"layer: unknown key `%@`", from);
            if (f == key_escape) return fail(error, @"layer: escape can't be remapped");
            if (!parse_key(layer[from], &t)) return fail(error, @"layer.%@: unknown key `%@`", from, layer[from]);
            config->layer[f] = t;
        }
    }

    id bindings = root[@"bindings"];
    if (bindings) {
        if (![bindings isKindOfClass:NSArray.class]) return fail(error, @"bindings: expected an array");
        NSMutableArray *parsed = [NSMutableArray array];
        NSUInteger i = 0;
        for (id entry in bindings) {
            kid_binding *b = [kid_binding new];
            if (![entry isKindOfClass:NSDictionary.class]) return fail(error, @"bindings[%lu]: expected an object", i);
            for (NSString *field in entry) {
                if (![@[@"key", @"modifiers", @"command", @"unless_apps"] containsObject:field]) {
                    return fail(error, @"bindings[%lu]: unknown field `%@`", i, field);
                }
            }
            if (!parse_key(entry[@"key"], &b->key)) {
                return fail(error, @"bindings[%lu].key: unknown key `%@`", i, entry[@"key"]);
            }
            id mods = entry[@"modifiers"] ?: @[];
            if (![mods isKindOfClass:NSArray.class]) return fail(error, @"bindings[%lu].modifiers: expected an array", i);
            for (id mod in mods) {
                if (![mod isKindOfClass:NSString.class]) return fail(error, @"bindings[%lu].modifiers: expected strings", i);
                if ([mod isEqualToString:@"hyper"]) {
                    b->hyper = true;
                    continue;
                }
                bool found = false;
                for (size_t m = 0; m < sizeof modifier_names / sizeof *modifier_names; m++) {
                    if (!strcmp(modifier_names[m].name, [mod UTF8String])) {
                        b->sides[modifier_names[m].mod] = side_merge(b->sides[modifier_names[m].mod], modifier_names[m].side);
                        found = true;
                    }
                }
                if (!found) return fail(error, @"bindings[%lu].modifiers: unknown modifier `%@`", i, mod);
            }
            if (b->hyper && b->key == key_escape) {
                return fail(error, @"bindings[%lu]: hyper+escape can't be bound", i);
            }
            if (b->hyper && config->layer[b->key] >= 0) {
                return fail(error, @"bindings[%lu]: hyper+%s is unreachable, since %s is in the layer", i, key_name(b->key), key_name(b->key));
            }
            id command = entry[@"command"];
            if (![command isKindOfClass:NSString.class] || ![command length]) {
                return fail(error, @"bindings[%lu].command: expected a non-empty string", i);
            }
            b.command = command;
            id apps = entry[@"unless_apps"] ?: @[];
            if (![apps isKindOfClass:NSArray.class]) return fail(error, @"bindings[%lu].unless_apps: expected an array", i);
            for (id app in apps) {
                if (![app isKindOfClass:NSString.class]) return fail(error, @"bindings[%lu].unless_apps: expected bundle identifiers", i);
            }
            b.unless_apps = [NSSet setWithArray:apps];
            [parsed addObject:b];
            i++;
        }
        config.bindings = parsed;
    }

    return config;
}

@end
