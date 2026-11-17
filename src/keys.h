#pragma once

#include <CoreGraphics/CoreGraphics.h>
#include <stdbool.h>

enum {
    key_escape = 53,
};

bool key_from_name(const char *name, CGKeyCode *code);
const char *key_name(CGKeyCode code);
CGEventFlags key_implicit_flags(CGKeyCode code);
