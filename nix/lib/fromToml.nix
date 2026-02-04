# Parse TOML config and build sandboxed environments
{ pkgs, jail, presets }:

configPath:

let
  # Parse TOML config
  config = builtins.fromTOML (builtins.readFile configPath);

  # Create backends (jail backend uses the passed jail function)
  backends = import ../backends { inherit pkgs jail; };

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

  # Build a single environment from config
  buildEnv = name: envConfig:
    let
      # Resolve the base environment package
      baseEnv =
        if envConfig ? preset then
          presets.${envConfig.preset} or (throw "Unknown preset: ${envConfig.preset}")
        else if envConfig ? flake then
          # Phase 2a.3: Custom flake support
          throw "Custom flake inputs not yet supported (Phase 2a.3)"
        else
          throw "Environment '${name}' must specify 'preset' or 'flake'";

      # Determine interpreter based on preset or explicit config
      interpreterInfo =
        if envConfig ? preset then
          {
            shell = { fn = jailBackend.mkShellEnv; };
            python = { fn = jailBackend.mkPythonEnv; };
            node = { fn = jailBackend.mkNodeEnv; };
          }.${envConfig.preset} or (throw "No interpreter mapping for preset: ${envConfig.preset}")
        else
          throw "Custom interpreter config not yet supported";

      # Build the jailed environment with project mounting (always readonly)
      jailedEnv = interpreterInfo.fn {
        inherit name projectPath projectMount;
        env = baseEnv;
      };

      # Extract config values with defaults
      timeout = envConfig.timeout_seconds or config.defaults.timeout_seconds or 30;
      memory = envConfig.memory_mb or config.defaults.memory_mb or 512;
    in {
      drv = jailedEnv;
      meta = {
        backend = "jail";
        exec = "${jailedEnv}/bin/run";
        timeout_seconds = timeout;
        memory_mb = memory;
      };
    };

  # Build all environments
  environments = builtins.mapAttrs buildEnv (config.environments or {});

  # Collect all derivations (for runtimeInputs)
  drvs = builtins.attrValues (builtins.mapAttrs (_: e: e.drv) environments);

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

  # Full metadata structure expected by daemon
  # Shape: { environments: {...}, project?: {...} }
  fullMetadata = {
    environments = envMetadata;
  } // (if projectConfig != null then { project = projectConfig; } else {});

  metadataJson = builtins.toJSON fullMetadata;

in {
  inherit drvs metadataJson environments;

  # For debugging
  inherit config;
  metadata = fullMetadata;
}
