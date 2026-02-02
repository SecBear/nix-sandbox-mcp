{
  description = "Nix-native sandboxed code execution for MCP";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    flake-parts.url = "github:hercules-ci/flake-parts";
    jail-nix.url = "sourcehut:~alexdavid/jail.nix";

    # Future: microvm backend
    # microvm = {
    #   url = "github:astro/microvm.nix";
    #   inputs.nixpkgs.follows = "nixpkgs";
    # };

    fenix = {
      url = "github:nix-community/fenix";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs =
    inputs@{ flake-parts, ... }:
    flake-parts.lib.mkFlake { inherit inputs; } {
      systems = [
        "x86_64-linux"
        "aarch64-linux"
        "x86_64-darwin"
        "aarch64-darwin"
      ];

      perSystem =
        {
          config,
          self',
          inputs',
          pkgs,
          system,
          ...
        }:
        let
          isLinux = pkgs.stdenv.isLinux;

          rustToolchain = inputs'.fenix.packages.stable.withComponents [
            "cargo"
            "clippy"
            "rust-src"
            "rustc"
            "rustfmt"
            "rust-analyzer"
          ];

          jail = if isLinux then inputs.jail-nix.lib.init pkgs else null;

          presets = if isLinux then import ./nix/environments { inherit pkgs; } else { };

          daemon = pkgs.rustPlatform.buildRustPackage {
            pname = "nix-sandbox-mcp-daemon";
            version = "0.1.0";
            src = ./daemon;
            cargoLock.lockFile = ./daemon/Cargo.lock;
          };

          mkServer =
            configPath:
            let
              built = import ./nix/lib/fromToml.nix {
                inherit pkgs jail presets;
              } configPath;
            in
            pkgs.writeShellApplication {
              name = "nix-sandbox-mcp";
              runtimeInputs = [ daemon ] ++ built.drvs;
              text = ''
                export NIX_SANDBOX_METADATA='${built.metadataJson}'
                exec nix-sandbox-mcp-daemon "$@"
              '';
            };

        in
        {
          _module.args.pkgs = import inputs.nixpkgs {
            inherit system;
            overlays = [ inputs.fenix.overlays.default ];
          };

          # ─────────────────────────────────────────────────────────
          # Packages
          # ─────────────────────────────────────────────────────────

          packages = {
            inherit daemon;
            default = if isLinux then mkServer ./config.example.toml else daemon;
          } // pkgs.lib.optionalAttrs isLinux {
            # Expose presets for direct building/testing
            "presets.shell" = presets.shell;
            "presets.python" = presets.python;
            "presets.node" = presets.node;
          };

          # Debug outputs for development
          debug = pkgs.lib.optionalAttrs isLinux {
            # Raw TOML parsing result
            fromToml = import ./nix/lib/fromToml.nix {
              inherit pkgs jail presets;
            } ./config.example.toml;

            # Just the metadata
            metadata = (import ./nix/lib/fromToml.nix {
              inherit pkgs jail presets;
            } ./config.example.toml).metadata;

            # Individual environments
            environments = (import ./nix/lib/fromToml.nix {
              inherit pkgs jail presets;
            } ./config.example.toml).environments;

            # Presets
            inherit presets;
          };

          # Integration tests
          checks = pkgs.lib.optionalAttrs isLinux {
            integration = import ./nix/tests {
              inherit pkgs;
              mcpServer = mkServer ./config.example.toml;
            };
          };

          # ─────────────────────────────────────────────────────────
          # Development shell
          # ─────────────────────────────────────────────────────────

          devShells.default = pkgs.mkShell {
            buildInputs = [
              rustToolchain
              pkgs.cargo-watch
              pkgs.cargo-edit
              pkgs.nixd
              pkgs.nixfmt
              pkgs.jq
            ]
            ++ pkgs.lib.optionals isLinux [
              pkgs.bubblewrap
            ];

            RUST_SRC_PATH = "${rustToolchain}/lib/rustlib/src/rust/library";

            shellHook = ''
              echo "nix-sandbox-mcp dev shell"
              echo ""
              echo "  cargo build    - Build daemon"
              echo "  cargo watch    - Build with hot reload"
              echo "  nix build      - Build everything"
              ${if isLinux then "" else ''echo "  (sandboxing requires Linux)"''}
              echo ""
            '';
          };
        };

      flake = {
        lib = {
          # Expose mkServer for users to build custom configurations
          # Usage: nix-sandbox-mcp.lib.mkServer ./my-config.toml
        };
      };
    };
}
