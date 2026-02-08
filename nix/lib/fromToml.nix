# Parse TOML config and build sandboxed environments
{ pkgs, jail, presets, agentPkg ? null }:

configPath:

let
  # Parse TOML config
  config = builtins.fromTOML (builtins.readFile configPath);

  # Create backends (jail backend uses the passed jail function)
  backends = import ../backends { inherit pkgs jail agentPkg; };

  # Use jail backend for MVP
  jailBackend = backends.jail;

  # Get the directory containing the config file (for resolving relative paths)
  configDir = builtins.dirOf configPath;

  # Resolve project path if configured
  # For "." or relative paths, resolve relative to config directory
  # Note: builtins.path copies the path to the store - this makes builds reproducible
  # and ensures the project is always mounted readonly (Nix store is immutable)
  projectPath = if config ? project then
    let
      rawPath = config.project.path or ".";
      # Resolve relative to config directory
      resolvedPath = if rawPath == "." then configDir
                     else if builtins.substring 0 1 rawPath == "/" then rawPath
                     else configDir + "/" + rawPath;
    in builtins.toString (builtins.path { path = resolvedPath; name = "project"; })
  else null;

  projectMount = if config ? project then config.project.mount_point or "/project" else "/project";

  # Preset interpreter mappings (interpreter command and stdinMode)
  presetInterpreters = {
    shell = { interpreter = "bash -s"; stdinMode = "pipe"; };
    python = { interpreter = "python3 -c"; stdinMode = "arg"; };
    node = { interpreter = "node -e"; stdinMode = "arg"; };
  };

  # Parse a flake reference like "github:owner/repo#attr" or "/path#attr"
  parseFlakeRef = flakeRef:
    let
      # Match "flakeref#attr" or just "flakeref"
      parts = builtins.match "([^#]+)#?(.*)" flakeRef;
      ref = builtins.elemAt parts 0;
      attrPath = builtins.elemAt parts 1;
    in { inherit ref attrPath; };

  # Navigate a flake's attribute path (e.g., "jq" or "packages.x86_64-linux.default")
  # Follows nix CLI conventions:
  # - Simple name (e.g., "jq") -> try packages.${system}.{name}, then legacyPackages.${system}.{name}
  # - Full path (e.g., "packages.x86_64-linux.foo") -> navigate directly
  navigateAttrs = flake: attrPath:
    if attrPath == "" || attrPath == null then
      # Default to packages.${system}.default
      flake.packages.${pkgs.system}.default
    else
      let
        # Split on "." and filter empty strings
        attrs = builtins.filter (s: s != "") (builtins.split "\\." attrPath);

        # Check if it's a simple package name (no dots) vs a full path
        isSimpleName = builtins.length attrs == 1;
        name = builtins.head attrs;

        # Try packages.${system}.{name} first, then legacyPackages.${system}.{name}
        tryPackages =
          if flake ? packages && flake.packages ? ${pkgs.system} && flake.packages.${pkgs.system} ? ${name}
          then flake.packages.${pkgs.system}.${name}
          else if flake ? legacyPackages && flake.legacyPackages ? ${pkgs.system} && flake.legacyPackages.${pkgs.system} ? ${name}
          then flake.legacyPackages.${pkgs.system}.${name}
          else throw "Package '${name}' not found in flake (tried packages.${pkgs.system}.${name} and legacyPackages.${pkgs.system}.${name})";

        # Navigate full path directly
        navigatePath = builtins.foldl' (acc: attr: acc.${attr}) flake attrs;
      in
        if isSimpleName then tryPackages else navigatePath;

  # Determine stdinMode from interpreter command
  # "-c" and "-e" flags expect code as argument, "-s" reads from stdin
  getStdinMode = interpreter:
    let
      words = builtins.filter (s: builtins.isString s && s != "")
        (builtins.split " " interpreter);
      lastArg = if words == [] then "" else builtins.elemAt words (builtins.length words - 1);
    in
      if lastArg == "-c" || lastArg == "-e" then "arg"
      else "pipe";

  # Build a single environment from config
  buildEnv = name: envConfig:
    let
      # Resolve the base environment package
      baseEnv =
        if envConfig ? preset then
          presets.${envConfig.preset} or (throw "Unknown preset: ${envConfig.preset}")
        else if envConfig ? flake then
          let
            parsed = parseFlakeRef envConfig.flake;
            flake = builtins.getFlake parsed.ref;
            pkg = navigateAttrs flake parsed.attrPath;
          in
            # Wrap flake package with essential tools (bash, coreutils)
            # needed by the runner script
            pkgs.buildEnv {
              name = "sandbox-env-${name}";
              paths = [
                pkg
                pkgs.bash
                pkgs.coreutils
              ];
            }
        else
          throw "Environment '${name}' must specify 'preset' or 'flake'";

      # Determine interpreter and stdinMode
      interpreterConfig =
        if envConfig ? interpreter then
          # Explicit interpreter from config
          { interpreter = envConfig.interpreter; stdinMode = getStdinMode envConfig.interpreter; }
        else if envConfig ? preset then
          # Use preset defaults
          presetInterpreters.${envConfig.preset} or (throw "No interpreter mapping for preset: ${envConfig.preset}")
        else
          # Default for flake environments
          { interpreter = "bash -s"; stdinMode = "pipe"; };

      # Build the jailed environment with project mounting (always readonly)
      jailedEnv = jailBackend.mkJailedEnv {
        inherit name projectPath projectMount;
        env = baseEnv;
        interpreter = interpreterConfig.interpreter;
        stdinMode = interpreterConfig.stdinMode;
      };

      # Build session variant (if agent is available)
      sessionJailedEnv = if agentPkg != null then
        jailBackend.mkSessionJailedEnv {
          inherit name projectPath projectMount;
          env = baseEnv;
        }
      else null;

      # Extract config values with defaults
      timeout = envConfig.timeout_seconds or config.defaults.timeout_seconds or 30;
      memory = envConfig.memory_mb or config.defaults.memory_mb or 512;
    in {
      drv = jailedEnv;
      sessionDrv = sessionJailedEnv;
      meta = {
        backend = "jail";
        exec = "${jailedEnv}/bin/run";
        timeout_seconds = timeout;
        memory_mb = memory;
      } // (if sessionJailedEnv != null then {
        session_exec = "${sessionJailedEnv}/bin/run";
      } else {});
    };

  # Build all environments from explicit config
  explicitEnvironments = builtins.mapAttrs buildEnv (config.environments or {});

  # Build "project" environment if use_flake = true
  # This uses the project's own flake.nix devShell
  projectEnvironment =
    if (config.project.use_flake or false) then
      let
        # Resolve the project path
        rawPath = config.project.path or ".";
        resolvedPath = if rawPath == "." then configDir
                       else if builtins.substring 0 1 rawPath == "/" then rawPath
                       else configDir + "/" + rawPath;

        # Load the project's flake
        projectFlake = builtins.getFlake (builtins.toString resolvedPath);

        # Find the devShell - try standard locations
        devShell =
          if projectFlake ? devShells && projectFlake.devShells ? ${pkgs.system} && projectFlake.devShells.${pkgs.system} ? default then
            projectFlake.devShells.${pkgs.system}.default
          else if projectFlake ? devShell && projectFlake.devShell ? ${pkgs.system} then
            projectFlake.devShell.${pkgs.system}
          else
            throw "Project flake has no devShell (tried devShells.${pkgs.system}.default and devShell.${pkgs.system})";

        # Extract packages from devShell
        # devShells created by mkShell have buildInputs and nativeBuildInputs
        packages = (devShell.buildInputs or []) ++ (devShell.nativeBuildInputs or []);

        # Create environment with devShell packages
        env = pkgs.buildEnv {
          name = "project-devshell";
          paths = packages ++ [
            pkgs.bash
            pkgs.coreutils
          ];
        };

        # Environment variables to inherit
        inheritVars = config.project.inherit_env.vars or [];

        # Build the jailed environment
        jailedEnv = jailBackend.mkJailedEnv {
          name = "project";
          inherit env projectPath projectMount inheritVars;
          interpreter = "bash -s";
          stdinMode = "pipe";
        };

        # Config values with defaults
        timeout = config.defaults.timeout_seconds or 30;
        memory = config.defaults.memory_mb or 512;
        # Build session variant for project env (if agent available)
        sessionJailedEnv = if agentPkg != null then
          jailBackend.mkSessionJailedEnv {
            name = "project";
            env = env;
            inherit projectPath projectMount;
          }
        else null;
      in {
        project = {
          drv = jailedEnv;
          sessionDrv = sessionJailedEnv;
          meta = {
            backend = "jail";
            exec = "${jailedEnv}/bin/run";
            timeout_seconds = timeout;
            memory_mb = memory;
          } // (if sessionJailedEnv != null then {
            session_exec = "${sessionJailedEnv}/bin/run";
          } else {});
        };
      }
    else {};

  # Merge explicit environments with project environment
  environments = explicitEnvironments // projectEnvironment;

  # Collect all derivations (for runtimeInputs) — includes both ephemeral and session wrappers
  ephemeralDrvs = builtins.attrValues (builtins.mapAttrs (_: e: e.drv) environments);
  sessionDrvs = builtins.filter (d: d != null)
    (builtins.attrValues (builtins.mapAttrs (_: e: e.sessionDrv or null) environments));
  drvs = ephemeralDrvs ++ sessionDrvs;

  # Generate environment metadata (exec paths, timeouts, etc.)
  envMetadata = builtins.mapAttrs (_: e: e.meta) environments;

  # Build project config for daemon (if configured)
  # Note: Project is always mounted readonly for security and reproducibility
  projectConfig = if config ? project then {
    path = config.project.path or ".";
    mount_point = config.project.mount_point or "/project";
    use_flake = config.project.use_flake or false;
    inherit_env = config.project.inherit_env or { vars = []; };
  } else null;

  # Session config for daemon (if configured)
  sessionConfig = if config ? session then {
    idle_timeout_seconds = config.session.idle_timeout_seconds or 300;
    max_lifetime_seconds = config.session.max_lifetime_seconds or 3600;
  } else null;

  # Full metadata structure expected by daemon
  # Shape: { environments: {...}, project?: {...}, session?: {...} }
  fullMetadata = {
    environments = envMetadata;
  } // (if projectConfig != null then { project = projectConfig; } else {})
    // (if sessionConfig != null then { session = sessionConfig; } else {});

  metadataJson = builtins.toJSON fullMetadata;

in {
  inherit drvs metadataJson environments;

  # For debugging
  inherit config;
  metadata = fullMetadata;
}
