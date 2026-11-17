#include "keys.h"

#include <string.h>

static const struct {
    const char *name;
    CGKeyCode code;
} keys[] = {
    {"a", 0}, {"s", 1}, {"d", 2}, {"f", 3}, {"h", 4}, {"g", 5}, {"z", 6}, {"x", 7},
    {"c", 8}, {"v", 9}, {"non_us_backslash", 10}, {"b", 11}, {"q", 12}, {"w", 13},
    {"e", 14}, {"r", 15}, {"y", 16}, {"t", 17}, {"1", 18}, {"2", 19}, {"3", 20},
    {"4", 21}, {"6", 22}, {"5", 23}, {"equal", 24}, {"9", 25}, {"7", 26}, {"minus", 27},
    {"8", 28}, {"0", 29}, {"right_bracket", 30}, {"o", 31}, {"u", 32},
    {"left_bracket", 33}, {"i", 34}, {"p", 35}, {"return", 36}, {"l", 37}, {"j", 38},
    {"quote", 39}, {"k", 40}, {"semicolon", 41}, {"backslash", 42}, {"comma", 43},
    {"slash", 44}, {"n", 45}, {"m", 46}, {"period", 47}, {"tab", 48}, {"space", 49},
    {"grave", 50}, {"delete", 51}, {"escape", 53},
    {"f1", 122}, {"f2", 120}, {"f3", 99}, {"f4", 118}, {"f5", 96}, {"f6", 97},
    {"f7", 98}, {"f8", 100}, {"f9", 101}, {"f10", 109}, {"f11", 103}, {"f12", 111},
    {"f13", 105}, {"f14", 107}, {"f15", 113}, {"f16", 106}, {"f17", 64}, {"f18", 79},
    {"f19", 80}, {"f20", 90},
    {"home", 115}, {"page_up", 116}, {"forward_delete", 117}, {"end", 119},
    {"page_down", 121}, {"left_arrow", 123}, {"right_arrow", 124}, {"down_arrow", 125},
    {"up_arrow", 126},
};

bool key_from_name(const char *name, CGKeyCode *code) {
    for (size_t i = 0; i < sizeof keys / sizeof *keys; i++) {
        if (!strcmp(keys[i].name, name)) {
            *code = keys[i].code;
            return true;
        }
    }
    return false;
}

const char *key_name(CGKeyCode code) {
    for (size_t i = 0; i < sizeof keys / sizeof *keys; i++) {
        if (keys[i].code == code) return keys[i].name;
    }
    return "?";
}

CGEventFlags key_implicit_flags(CGKeyCode code) {
    switch (code) {
        case 123: case 124: case 125: case 126:
            return kCGEventFlagMaskSecondaryFn | kCGEventFlagMaskNumericPad;
        case 115: case 116: case 117: case 119: case 121:
        case 122: case 120: case 99: case 118: case 96: case 97: case 98: case 100:
        case 101: case 109: case 103: case 111: case 105: case 107: case 113: case 106:
        case 64: case 79: case 80: case 90:
            return kCGEventFlagMaskSecondaryFn;
        default:
            return 0;
    }
}
