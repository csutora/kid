{
  description = "pinky - caps lock as escape and hyper, with keybindings and caps lock led control";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";
  };

  outputs = { self, nixpkgs }:
    let
      systems = [ "aarch64-darwin" ];
      forAll = f: nixpkgs.lib.genAttrs systems (system: f nixpkgs.legacyPackages.${system});

      version = "0.1.0";

      # the release tarball holds an app bundle signed with a stable identity, so
      # macos keeps the accessibility and input monitoring grants across updates
      url = "https://github.com/csutora/pinky/releases/download/v${version}/pinky-${version}-aarch64-darwin.tar.gz";
      hash = "sha256-tT5rGZ9zTVd6JjXvoqW5N8zwGslpXG9cXUlUXltiSl0=";

      mkPinky = pkgs: pkgs.stdenv.mkDerivation {
        pname = "pinky";
        inherit version;
        src = pkgs.fetchurl { inherit url hash; };

        sourceRoot = ".";
        dontBuild = true;
        dontConfigure = true;
        dontFixup = true;

        unpackPhase = ''
          tar xzf $src
        '';

        installPhase = ''
          mkdir -p $out/Applications $out/bin
          cp -R pinky.app $out/Applications/
          ln -s $out/Applications/pinky.app/Contents/MacOS/pinky $out/bin/pinky
        '';

        meta = {
          description = "caps lock as escape and hyper, with keybindings and caps lock led control";
          homepage = "https://github.com/csutora/pinky";
          license = pkgs.lib.licenses.mit;
          platforms = systems;
          mainProgram = "pinky";
        };
      };
    in
    {
      packages = forAll (pkgs: rec {
        pinky = mkPinky pkgs;
        default = pinky;
      });

      devShells = forAll (pkgs: {
        default = pkgs.mkShell {
          packages = [ pkgs.clang-tools ];

          shellHook = ''
            IDENTITY=$(security find-identity -v -p codesigning 2>/dev/null | awk '/Apple Development/ {print $2; exit}')
            if [ -n "$IDENTITY" ]; then
              export CODESIGN_IDENTITY="$IDENTITY"
            fi
          '';
        };
      });

      overlays.default = final: prev: {
        pinky = self.packages.${prev.stdenv.hostPlatform.system}.pinky;
      };

      homeModules.default = import ./nix/home-module.nix self;
    };
}
