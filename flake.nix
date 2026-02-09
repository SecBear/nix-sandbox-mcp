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

          agentPkg = if isLinux then import ./agent { inherit pkgs; } else null;

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
                inherit pkgs jail presets agentPkg;
              } configPath;
            in
            pkgs.writeShellApplication {
              name = "nix-sandbox-mcp";
              runtimeInputs = [ daemon ] ++ built.drvs;
              text = ''
                export NIX_SANDBOX_METADATA='${built.metadataJson}'

                # Build custom environments from flake refs (if specified)
                if [ -n "''${NIX_SANDBOX_ENVS:-}" ]; then
                  SANDBOX_TMPDIR=$(mktemp -d)

                  # Merge in existing sandbox dir
                  _DEFAULT_DIR="''${NIX_SANDBOX_DIR:-''${HOME}/.config/nix-sandbox-mcp/sandboxes}"
                  if [ -d "$_DEFAULT_DIR" ]; then
                    for entry in "$_DEFAULT_DIR"/*/; do
                      [ -d "$entry" ] && ln -s "$(readlink -f "$entry")" "$SANDBOX_TMPDIR/$(basename "$entry")" 2>/dev/null || true
                    done
                  fi

                  # Build each flake ref
                  j=0
                  for flakeref in $(echo "''${NIX_SANDBOX_ENVS}" | tr ',' '\n'); do
                    flakeref=$(echo "$flakeref" | xargs)
                    [ -z "$flakeref" ] && continue
                    echo "nix-sandbox-mcp: building $flakeref..." >&2
                    if nix build "$flakeref" -o "$SANDBOX_TMPDIR/env-$j"; then
                      j=$((j + 1))
                    else
                      echo "nix-sandbox-mcp: warning: failed to build $flakeref" >&2
                    fi
                  done

                  export NIX_SANDBOX_DIR="$SANDBOX_TMPDIR"
                fi

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

            # Test sandbox artifact (validates mkSandbox pipeline)
            "test-sandbox" = import ./nix/lib/mkSandbox.nix {
              inherit pkgs jail agentPkg;
            } {
              name = "test-sandbox";
              interpreter_type = "python";
              packages = [ pkgs.python3 ];
            };
          };

          # Debug outputs for development
          debug = pkgs.lib.optionalAttrs isLinux {
            # Raw TOML parsing result
            fromToml = import ./nix/lib/fromToml.nix {
              inherit pkgs jail presets agentPkg;
            } ./config.example.toml;

            # Just the metadata
            metadata = (import ./nix/lib/fromToml.nix {
              inherit pkgs jail presets agentPkg;
            } ./config.example.toml).metadata;

            # Individual environments
            environments = (import ./nix/lib/fromToml.nix {
              inherit pkgs jail presets agentPkg;
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
        # Public library: build standalone sandbox artifacts
        lib.mkSandbox =
          { pkgs, ... }@args:
          let
            jail = inputs.jail-nix.lib.init pkgs;
            agentPkg = import ./agent { inherit pkgs; };
            fn = import ./nix/lib/mkSandbox.nix { inherit pkgs jail agentPkg; };
          in
          fn (builtins.removeAttrs args [ "pkgs" ]);
      };
    };
}
