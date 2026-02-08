# Nix library for nix-sandbox-mcp
{ pkgs, jail, presets, agentPkg ? null }:

let
  backends = import ../backends { inherit pkgs jail agentPkg; };
in {
  fromToml = import ./fromToml.nix { inherit pkgs jail presets agentPkg; };
  inherit backends;
}
