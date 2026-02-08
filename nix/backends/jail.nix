# jail.nix backend - wraps environments in bubblewrap sandboxes
{ pkgs, jail, agentPkg ? null }:

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
  #   projectPath: Optional path to mount as project directory (null = no project)
  #   projectMount: Mount point for project inside sandbox (default: /project)
  # Note: Project is always mounted read-only for security and reproducibility
  mkJailedEnv = {
    name,
    env,
    interpreter,
    stdinMode ? "arg",  # "arg" = pass as argument, "pipe" = pipe to stdin
    projectPath ? null,
    projectMount ? "/project",
    inheritVars ? [],  # Environment variable names to inherit from host
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

      # Capture inherited environment variables at build time
      # Note: builtins.getEnv only works in impure mode, so this only
      # captures vars during impure builds (which is fine for development)
      inheritedEnvCombs = builtins.filter (x: x != null) (
        map (varName:
          let val = builtins.getEnv varName;
          in if val != "" then { name = varName; value = val; } else null
        ) inheritVars
      );

      # Wrap with jail.nix
      # jail returns a derivation with bin/sandbox-${name} executable
      # Pass the explicit path to the runner script executable
      jailed = jail "sandbox-${name}" "${runnerScript}/bin/runner-${name}" (c:
        let
          # Project mounting combinator (if project path configured)
          # Always read-only for security and reproducibility
          projectCombs = if projectPath != null then [
            (c.ro-bind projectPath projectMount)
          ] else [];

          # Environment variable combinators
          envVarCombs = map (e: c.set-env e.name e.value) inheritedEnvCombs;
        in [
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
        ] ++ projectCombs ++ envVarCombs);
    in
      # Return derivation with /bin/run pointing to the jailed script
      # ${jailed} is a derivation with bin/sandbox-${name} executable
      pkgs.runCommand "jailed-${name}" { } ''
        mkdir -p $out/bin
        ln -s ${jailed}/bin/sandbox-${name} $out/bin/run
      '';

  # Convenience wrappers for common interpreters
  # All accept optional project mounting params: projectPath, projectMount
  mkPythonEnv = { name, env, projectPath ? null, projectMount ? "/project" }: mkJailedEnv {
    inherit name env projectPath projectMount;
    interpreter = "python3 -c";
    stdinMode = "arg";
  };

  mkShellEnv = { name, env, projectPath ? null, projectMount ? "/project" }: mkJailedEnv {
    inherit name env projectPath projectMount;
    interpreter = "bash -s";
    stdinMode = "pipe";
  };

  mkNodeEnv = { name, env, projectPath ? null, projectMount ? "/project" }: mkJailedEnv {
    inherit name env projectPath projectMount;
    interpreter = "node -e";
    stdinMode = "arg";
  };

  # Create a session-enabled jailed wrapper for an environment.
  # Reuses mkJailedEnv with the sandbox agent as the interpreter.
  # The agent runs as a long-lived process, maintaining interpreter
  # state across executions via length-prefixed JSON on stdin/stdout.
  #
  # Arguments:
  #   name: Environment name (e.g., "python")
  #   env: The environment package (from nix/environments/)
  #   projectPath: Optional path to mount as project directory
  #   projectMount: Mount point for project inside sandbox
  mkSessionJailedEnv = {
    name,
    env,
    projectPath ? null,
    projectMount ? "/project",
  }:
    assert agentPkg != null;
    let
      # Merge the original env with the agent and python3 (agent runtime)
      sessionEnv = pkgs.buildEnv {
        name = "session-env-${name}";
        paths = [
          env
          agentPkg
          pkgs.python3  # Agent runtime (may overlap with python preset)
        ];
        ignoreCollisions = true;
      };
    in mkJailedEnv {
      name = "session-${name}";
      env = sessionEnv;
      interpreter = "sandbox-agent";
      stdinMode = "pipe";
      inherit projectPath projectMount;
    };
}
