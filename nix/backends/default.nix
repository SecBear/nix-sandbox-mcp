# All available isolation backends
{ pkgs, jail, agentPkg ? null }:

{
  jail = import ./jail.nix { inherit pkgs jail agentPkg; };
  # Future: microvm = import ./microvm.nix { inherit pkgs microvm; };
}
