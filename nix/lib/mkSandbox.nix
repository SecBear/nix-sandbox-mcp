# mkSandbox — build a standalone sandbox artifact for nix-sandbox-mcp.
#
# Produces a derivation with standard layout:
#   $out/metadata.json       # {name, interpreter_type, timeout_seconds, memory_mb}
#   $out/bin/run             # Ephemeral execution wrapper (jailed)
#   $out/bin/session-run     # Session execution wrapper (jailed)
#
# Project mounting happens at runtime via PROJECT_DIR/PROJECT_MOUNT env vars,
# so the artifact is project-agnostic — build once, use everywhere.
#
# Usage:
#   mkSandbox {
#     name = "data-science";
#     interpreter_type = "python";   # required: "python", "bash", or "node"
#     packages = [ (pkgs.python3.withPackages (ps: [ ps.numpy ps.pandas ])) ];
#   }

{ pkgs, jail, agentPkg }:

{
  name,
  interpreter_type,           # Required: "python", "bash", or "node"
  packages,                   # List of Nix packages to include
  timeout_seconds ? 30,
  memory_mb ? 512,
}:

let
  # Map interpreter_type to interpreter command and stdinMode
  interpreterConfig = {
    python = { interpreter = "python3 -c"; stdinMode = "arg"; };
    bash   = { interpreter = "bash -s";    stdinMode = "pipe"; };
    node   = { interpreter = "node -e";    stdinMode = "arg"; };
  }.${interpreter_type} or (throw "Unknown interpreter_type: '${interpreter_type}'. Must be one of: python, bash, node");

  # Build the combined environment package
  env = pkgs.buildEnv {
    name = "sandbox-env-${name}";
    paths = packages ++ [
      pkgs.bash
      pkgs.coreutils
    ];
  };

  backends = import ../backends { inherit pkgs jail agentPkg; };
  jailBackend = backends.jail;

  # Build ephemeral wrapper with runtime project mounting
  jailedEnv = jailBackend.mkJailedEnv {
    inherit name env;
    inherit (interpreterConfig) interpreter stdinMode;
    runtimeProjectMount = true;
  };

  # Build session wrapper with runtime project mounting
  sessionJailedEnv = jailBackend.mkSessionJailedEnv {
    inherit name env;
    runtimeProjectMount = true;
  };

  # metadata.json for the daemon's scanner
  metadataJson = builtins.toJSON {
    inherit name interpreter_type timeout_seconds memory_mb;
  };

in pkgs.runCommand "sandbox-${name}" { } ''
  mkdir -p $out/bin

  # Symlink execution wrappers
  ln -s ${jailedEnv}/bin/run $out/bin/run
  ln -s ${sessionJailedEnv}/bin/run $out/bin/session-run

  # Write metadata for daemon discovery
  cat > $out/metadata.json << 'EOF'
  ${metadataJson}
  EOF
''
