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

  # Build a single environment from config
  buildEnv = name: envConfig:
    let
      # Resolve the base environment package
      baseEnv =
        if envConfig ? preset then
          presets.${envConfig.preset} or (throw "Unknown preset: ${envConfig.preset}")
        else if envConfig ? flake then
          # Phase 2: Custom flake support
          throw "Custom flake inputs not yet supported (Phase 2)"
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

      # Build the jailed environment
      jailedEnv = interpreterInfo.fn {
        inherit name;
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

  # Generate metadata JSON (for NIX_SANDBOX_METADATA)
  metadata = builtins.mapAttrs (_: e: e.meta) environments;
  metadataJson = builtins.toJSON metadata;

in {
  inherit drvs metadataJson environments;

  # For debugging
  inherit config metadata;
}
