{
  description = "connect.hx -- a ConnectRPC client for the Helix editor";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    flake-parts.url = "github:hercules-ci/flake-parts";
    treefmt-nix.url = "github:numtide/treefmt-nix";

    # Provides `helixPlugins`, which carries both the cog builder
    # (`buildHelixPlugin`) and the two MIT cogs this plugin depends on
    # (`run-command`, `http2curl`). Nothing else from this flake is used --
    # its NixOS/home-manager modules would pull in a second helix build.
    helix-plugins.url = "github:maxschipper/helix-plugins-nix";
  };

  outputs = inputs @ {flake-parts, ...}:
    flake-parts.lib.mkFlake {inherit inputs;} {
      imports = [inputs.treefmt-nix.flakeModule];
      systems = ["x86_64-linux" "aarch64-linux" "x86_64-darwin" "aarch64-darwin"];

      flake.overlays.default = final: prev: {
        helixPlugins =
          (prev.helixPlugins or {})
          // {
            connect-hx = final.callPackage ./package.nix {};
          };
      };

      perSystem = {
        pkgs,
        system,
        ...
      }: let
        # The builder and the dependency cogs both live in the helixPlugins
        # scope, so callPackage from that scope resolves them by name.
        helixPlugins =
          (pkgs.appendOverlays [inputs.helix-plugins.overlays.default]).helixPlugins;
      in {
        packages.default = helixPlugins.callPackage ./package.nix {};
        packages.connect-hx = helixPlugins.callPackage ./package.nix {};

        treefmt = {
          projectRootFile = "flake.nix";
          programs.alejandra.enable = true;
        };

        devShells.default = pkgs.mkShell {
          packages = with pkgs; [
            # Steel itself, plus the LSP that backs the `scheme` language entry.
            # steel-language-server resolves its index out of $STEEL_HOME, which
            # the shellHook points at the dev cog tree below.
            steel
            steel-language-server

            # buf carries `buf curl`, the schema-aware executor: it speaks the
            # Connect protocol natively, pulls descriptors from server
            # reflection, and rejects unknown JSON fields client-side.
            buf

            # curl is the zero-schema fallback executor, and the only hard
            # runtime dependency of the plugin itself.
            curl

            # Handy when poking at descriptor sets and responses by hand.
            jq
            protobuf
            grpcurl
          ];

          # A throwaway STEEL_HOME holding this checkout plus its dependency
          # cogs, so `steel` at the prompt resolves `(require "connect.hx/...")`
          # exactly the way helix will. Rebuilt per shell; nothing persists.
          shellHook = ''
            export STEEL_HOME="''${STEEL_HOME:-$PWD/.dev/steel-home}"
            mkdir -p "$STEEL_HOME/cogs"
            ln -sfn "$PWD" "$STEEL_HOME/cogs/connect.hx"
            ln -sfn ${helixPlugins.run-command} "$STEEL_HOME/cogs/run-command"
            ln -sfn ${helixPlugins.http2curl} "$STEEL_HOME/cogs/http2curl"
            echo "connect.hx dev shell -- STEEL_HOME=$STEEL_HOME"
          '';
        };
      };
    };
}
