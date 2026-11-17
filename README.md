# pinky

makes the caps lock key useful

escape on tap, hyper on hold, hjkl arrow keys, configurable keybindings, caps lock led control.

## features

- escape on tap, hyper (cmd+ctrl+opt+shift) on hold
- a layer of remapped keys while caps lock is held, e.g. hjkl to arrows, keeping any other held modifiers (caps+shift+hjkl works for selection)
- keybindings that run shell commands, with left/right-aware modifiers and per-app exceptions
- caps lock led control from scripts with `pinky led on|off|auto`
- no drivers, no seized keyboard, no idle cpu use

## requirements

- macos on apple silicon
- a nix setup with home-manager

## install

### nix (flakes)

add pinky to your flake inputs:

```nix
{
    inputs = {
        nixpkgs.url = "github:nixos/nixpkgs/nixpkgs-unstable";

        nix-darwin = {
            url = "github:nix-darwin/nix-darwin";
            inputs.nixpkgs.follows = "nixpkgs";
        };

        home-manager = {
            url = "github:nix-community/home-manager";
            inputs.nixpkgs.follows = "nixpkgs";
        };

        pinky = {
            url = "github:csutora/pinky";
            inputs.nixpkgs.follows = "nixpkgs";
        };
    };

    outputs = { self, nixpkgs, nix-darwin, home-manager, pinky, ... }: {
        darwinConfigurations.your-hostname = nix-darwin.lib.darwinSystem {
            modules = [
                home-manager.darwinModules.home-manager
                {
                    home-manager.users.your-username = {
                        imports = [ pinky.homeModules.default ];
                    };
                }
            ];
        };
    };
}
```

then in your home-manager configuration:

```nix
services.pinky = {
    enable = true;
    settings = {
        layer = {
            h = "left_arrow";
            j = "down_arrow";
            k = "up_arrow";
            l = "right_arrow";
        };
        bindings = [
            {
                key = "v";
                modifiers = [ "hyper" ];
                command = "open -a ScreenSaverEngine";
            }
            {
                key = "t";
                modifiers = [ "right_command" ];
                command = "open -a Terminal";
                unless_apps = [ "com.moonlight-stream.Moonlight" ];
            }
        ];
    };
};
```

the config is validated with `pinky check` on darwin rebuilds.

## permissions

on first start, macos asks for two permissions for pinky:
- **input monitoring**, to tell caps lock apart from the escape key
- **accessibility**, to modify key events

## configuration

this is handled by home-manager, but pinky reads a json config from `~/.config/pinky/config.json` by default, or from the path given with `pinky daemon --config <path>`. the daemon reloads it on `SIGHUP`. options:

- `tap_timeout_ms`: holding caps lock longer than this and releasing it without pressing anything sends nothing. defaults to `1000`
- `layer`: keys remapped while caps lock is held. other held modifiers are kept, hyper isn't added
- `bindings`: shell commands run with `/bin/sh -c` when a key is pressed with exactly the given modifiers
  - `modifiers`: any of `hyper`, `command`, `option`, `control`, `shift`, or their `left_` and `right_` variants to only match one side
  - `unless_apps`: bundle identifiers of apps where the binding is ignored and the key is passed through

keys are named by their position on an ansi us keyboard:
`a` to `z`, `0` to `9`, `minus`, `equal`, `left_bracket`, `right_bracket`, `backslash`, `semicolon`, `quote`, `grave`, `comma`, `period`, `slash`, `non_us_backslash`, `return`, `tab`, `space`, `delete`, `forward_delete`, `escape`, `f1` to `f20`, `home`, `end`, `page_up`, `page_down`, `left_arrow`, `right_arrow`, `up_arrow`, `down_arrow`

## caps lock led

```sh
pinky led on     # force the led on
pinky led off    # force the led off
pinky led auto   # follow the caps lock state again
pinky led        # show the override and the led state as json

pinky led flash                       # flash twice, then return to the previous state
pinky led flash --times 3 --speed 2   # flash three times, twice as fast
```

flashing inverts the led and back, so it always ends where it started. it also handles overlapping flashes and on-off requests nicely.

the override applies to every keyboard with a caps lock led, including ones connected later. it isn't persisted, so it resets to `auto` when the daemon restarts.

## troubleshooting

**caps lock does nothing or types escape only**
- check that pinky is allowed in system settings > privacy & security > input monitoring and accessibility
- check the logs at `~/Library/Logs/pinky.log`

**caps lock is still escape after disabling pinky**
- the remap stays until you reboot. to undo it right away: `hidutil property --set '{"UserKeyMapping":[]}'`

**other key remaps made with `hidutil` disappeared**
- pinky owns the `hidutil` key mapping and replaces it on start, so use pinky's layer and bindings instead
