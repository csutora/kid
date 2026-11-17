#import <Foundation/Foundation.h>

#import "config.h"
#import "daemon.h"
#import "ipc.h"

static const char *usage =
    "kid " KID_VERSION "\n"
    "caps lock as escape and hyper, with keybindings and caps lock led control\n"
    "\n"
    "usage:\n"
    "  kid daemon [--config <path>]   run the daemon\n"
    "  kid check [<path>]             validate a config file\n"
    "  kid led [on|off|auto]          show or set the caps lock led override\n"
    "  kid led flash [--times <n>] [--speed <x>]\n"
    "                                   flash the led, then return to its state.\n"
    "                                   defaults to 2 times at speed 1\n"
    "  kid version                    print the version\n"
    "\n"
    "the config defaults to ~/.config/kid/config.json\n";

static int fail_usage(void) {
    fputs(usage, stderr);
    return 2;
}

static int check(NSString *path) {
    NSString *error;
    if (![kid_config load:path optional:false error:&error]) {
        fprintf(stderr, "kid: %s\n", error.UTF8String);
        return 1;
    }
    return 0;
}

static NSString *flash_request(NSArray<NSString *> *args) {
    long times = 2;
    double speed = 1;
    for (NSUInteger i = 0; i < args.count; i += 2) {
        if (i + 1 >= args.count) return nil;
        NSScanner *scanner = [NSScanner scannerWithString:args[i + 1]];
        if ([args[i] isEqualToString:@"--times"]) {
            if (![scanner scanInteger:&times] || !scanner.atEnd) return nil;
        } else if ([args[i] isEqualToString:@"--speed"]) {
            if (![scanner scanDouble:&speed] || !scanner.atEnd) return nil;
        } else {
            return nil;
        }
    }
    return [NSString stringWithFormat:@"led flash %ld %g", times, speed];
}

static int led(NSArray<NSString *> *args) {
    NSString *request = @"led";
    if (args.count && [args[0] isEqualToString:@"flash"]) {
        request = flash_request([args subarrayWithRange:NSMakeRange(1, args.count - 1)]);
        if (!request) return fail_usage();
    } else if (args.count == 1) {
        request = [@"led " stringByAppendingString:args[0]];
    } else if (args.count) {
        return fail_usage();
    }
    NSString *response = ipc_request(request);
    if (!response) {
        fprintf(stderr, "kid: could not reach the daemon at %s\n", ipc_socket_path().UTF8String);
        return 1;
    }
    NSDictionary *json = [NSJSONSerialization JSONObjectWithData:[response dataUsingEncoding:NSUTF8StringEncoding]
                                                         options:0
                                                           error:nil];
    if (![json isKindOfClass:NSDictionary.class]) {
        fprintf(stderr, "kid: unexpected response from the daemon: %s\n", response.UTF8String);
        return 1;
    }
    if (json[@"error"]) {
        fprintf(stderr, "kid: %s\n", [json[@"error"] description].UTF8String);
        return 1;
    }
    if (!args.count) puts(response.UTF8String);
    return 0;
}

int main(int argc, char **argv) {
    @autoreleasepool {
        NSMutableArray<NSString *> *args = [NSMutableArray array];
        for (int i = 1; i < argc; i++) [args addObject:@(argv[i])];
        if (!args.count) return fail_usage();
        NSString *command = args[0];
        [args removeObjectAtIndex:0];

        if ([command isEqualToString:@"daemon"]) {
            if (args.count == 2 && [args[0] isEqualToString:@"--config"]) return daemon_main(args[1], false);
            if (args.count) return fail_usage();
            return daemon_main(kid_config.default_path, true);
        }
        if ([command isEqualToString:@"check"]) {
            if (args.count > 1) return fail_usage();
            return check(args.count ? args[0] : kid_config.default_path);
        }
        if ([command isEqualToString:@"led"]) return led(args);
        if ([command isEqualToString:@"version"] || [command isEqualToString:@"--version"]) {
            puts(KID_VERSION);
            return 0;
        }
        if ([command isEqualToString:@"help"] || [command isEqualToString:@"--help"] || [command isEqualToString:@"-h"]) {
            fputs(usage, stdout);
            return 0;
        }
        return fail_usage();
    }
}
