# All available isolation backends
{ pkgs, jail }:

{
  jail = import ./jail.nix { inherit pkgs jail; };
  # Future: microvm = import ./microvm.nix { inherit pkgs microvm; };
}
