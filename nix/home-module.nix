flake: { config, lib, pkgs, ... }:

let
  cfg = config.services.pinky;
  settingsFormat = pkgs.formats.json { };

  configFile = pkgs.runCommand "pinky-config.json" {
    unchecked = settingsFormat.generate "pinky-config-unchecked.json" cfg.settings;
  } ''
    ${lib.getExe cfg.package} check $unchecked
    cp $unchecked $out
  '';
in
{
  options.services.pinky = {
    enable = lib.mkEnableOption "pinky, caps lock as escape and hyper, with keybindings and caps lock led control";

    package = lib.mkOption {
      type = lib.types.package;
      default = flake.packages.${pkgs.stdenv.hostPlatform.system}.pinky;
      defaultText = lib.literalExpression "inputs.pinky.packages.\${system}.pinky";
      description = "the pinky package to use.";
    };

    settings = lib.mkOption {
      type = settingsFormat.type;
      default = { };
      description = ''
        pinky configuration, serialized to json and validated with `pinky check` at build time.
      '';
      example = lib.literalExpression ''
        {
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
        }
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    assertions = [
      (lib.hm.assertions.assertPlatform "services.pinky" pkgs lib.platforms.darwin)
    ];

    home.packages = [ cfg.package ];

    home.file."Applications/pinky.app".source = "${cfg.package}/Applications/pinky.app";

    launchd.agents.pinky = {
      enable = true;
      config = {
        Label = "com.csutora.pinky";
        ProgramArguments = [
          "${cfg.package}/Applications/pinky.app/Contents/MacOS/pinky"
          "daemon"
          "--config"
          "${configFile}"
        ];
        RunAtLoad = true;
        KeepAlive = {
          SuccessfulExit = false;
        };
        ProcessType = "Interactive";
        StandardOutPath = "${config.home.homeDirectory}/Library/Logs/pinky.log";
        StandardErrorPath = "${config.home.homeDirectory}/Library/Logs/pinky.log";
      };
    };
  };
}
