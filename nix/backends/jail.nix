# jail.nix backend - wraps environments in bubblewrap sandboxes
{ pkgs, jail }:

rec {
  # Create a jailed wrapper for an environment
  # Returns a derivation with /bin/run that:
  #   1. Reads code from stdin
  #   2. Executes it in a sandboxed environment
  #   3. Outputs to stdout/stderr
  #
  # Arguments:
  #   name: Environment name (e.g., "python")
  #   env: The environment package (from nix/environments/)
  #   interpreter: Command to run code (e.g., "python3 -c")
  #   stdinMode: How to pass code - "arg" (python -c "$(cat)") or "pipe" (bash -s)
  mkJailedEnv = {
    name,
    env,
    interpreter,
    stdinMode ? "arg",  # "arg" = pass as argument, "pipe" = pipe to stdin
  }:
    let
      # The runner script that executes inside the jail
      # Note: interpreter commands (python3, bash, node) are available via add-pkg-deps
      # Use writeShellScriptBin to create a package with bin/ structure as expected by jail.nix
      runnerScript = if stdinMode == "arg" then
        pkgs.writeShellScriptBin "runner-${name}" ''
          set -euo pipefail
          cd /workspace
          code="$(cat)"
          exec ${interpreter} "$code"
        ''
      else
        pkgs.writeShellScriptBin "runner-${name}" ''
          set -euo pipefail
          cd /workspace
          exec ${interpreter}
        '';

      # Wrap with jail.nix
      # jail returns a derivation with bin/sandbox-${name} executable
      # Pass the explicit path to the runner script executable
      jailed = jail "sandbox-${name}" "${runnerScript}/bin/runner-${name}" (c: [
        # Minimal base: fake /proc, /dev, coreutils, bash
        c.base

        # Add environment packages to PATH
        # Note: add-pkg-deps handles PATH, don't override it manually
        (c.add-pkg-deps [ env ])

        # Writable workspace (created fresh each run, cleaned up on exit)
        (c.tmpfs "/workspace")
        (c.set-env "HOME" "/workspace")
        (c.set-env "TMPDIR" "/workspace")

        # No network access by default (security)
        # Network would require: c.network

        # Minimal environment variables
        (c.set-env "TERM" "dumb")
      ]);
    in
      # Return derivation with /bin/run pointing to the jailed script
      # ${jailed} is a derivation with bin/sandbox-${name} executable
      pkgs.runCommand "jailed-${name}" { } ''
        mkdir -p $out/bin
        ln -s ${jailed}/bin/sandbox-${name} $out/bin/run
      '';

  # Convenience wrappers for common interpreters
  mkPythonEnv = { name, env }: mkJailedEnv {
    inherit name env;
    interpreter = "python3 -c";
    stdinMode = "arg";
  };

  mkShellEnv = { name, env }: mkJailedEnv {
    inherit name env;
    interpreter = "bash -s";
    stdinMode = "pipe";
  };

  mkNodeEnv = { name, env }: mkJailedEnv {
    inherit name env;
    interpreter = "node -e";
    stdinMode = "arg";
  };
}
