{
  description = "kid - caps lock as escape and hyper, with keybindings and caps lock led control";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";
  };

  outputs = { self, nixpkgs }:
    let
      systems = [ "aarch64-darwin" ];
      forAll = f: nixpkgs.lib.genAttrs systems (system: f nixpkgs.legacyPackages.${system});

      version = "0.2.0";

      # the release tarball holds an app bundle signed with a stable identity, so
      # macos keeps the accessibility and input monitoring grants across updates
      url = "https://github.com/csutora/kid/releases/download/v${version}/kid-${version}-aarch64-darwin.tar.gz";
      hash = "sha256-9jAF/x9JCLOXmLpX9ZtymvlZLo4qSuuIM3gtG9va7Gs=";

      mkKid = pkgs: pkgs.stdenv.mkDerivation {
        pname = "kid";
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
          cp -R kid.app $out/Applications/
          ln -s $out/Applications/kid.app/Contents/MacOS/kid $out/bin/kid
        '';

        meta = {
          description = "caps lock as escape and hyper, with keybindings and caps lock led control";
          homepage = "https://github.com/csutora/kid";
          license = pkgs.lib.licenses.mit;
          platforms = systems;
          mainProgram = "kid";
        };
      };
    in
    {
      packages = forAll (pkgs: rec {
        kid = mkKid pkgs;
        default = kid;
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
        kid = self.packages.${prev.stdenv.hostPlatform.system}.kid;
      };

      homeModules.default = import ./nix/home-module.nix self;
    };
}
