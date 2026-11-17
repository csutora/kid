flake: { config, lib, pkgs, ... }:

let
  cfg = config.services.kid;
  settingsFormat = pkgs.formats.json { };

  configFile = pkgs.runCommand "kid-config.json" {
    unchecked = settingsFormat.generate "kid-config-unchecked.json" cfg.settings;
  } ''
    ${lib.getExe cfg.package} check $unchecked
    cp $unchecked $out
  '';
in
{
  options.services.kid = {
    enable = lib.mkEnableOption "kid, caps lock as escape and hyper, with keybindings and caps lock led control";

    package = lib.mkOption {
      type = lib.types.package;
      default = flake.packages.${pkgs.stdenv.hostPlatform.system}.kid;
      defaultText = lib.literalExpression "inputs.kid.packages.\${system}.kid";
      description = "the kid package to use.";
    };

    settings = lib.mkOption {
      type = settingsFormat.type;
      default = { };
      description = ''
        kid configuration, serialized to json and validated with `kid check` at build time.
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
      (lib.hm.assertions.assertPlatform "services.kid" pkgs lib.platforms.darwin)
    ];

    home.packages = [ cfg.package ];

    home.file."Applications/kid.app".source = "${cfg.package}/Applications/kid.app";

    launchd.agents.kid = {
      enable = true;
      config = {
        Label = "com.csutora.kid";
        ProgramArguments = [
          "${cfg.package}/Applications/kid.app/Contents/MacOS/kid"
          "daemon"
          "--config"
          "${configFile}"
        ];
        RunAtLoad = true;
        ProcessType = "Interactive";
        StandardOutPath = "${config.home.homeDirectory}/Library/Logs/kid.log";
        StandardErrorPath = "${config.home.homeDirectory}/Library/Logs/kid.log";
      };
    };
  };
}
