# All available preset environments
{ pkgs }:

{
  shell = import ./shell.nix { inherit pkgs; };
  python = import ./python.nix { inherit pkgs; };
  node = import ./node.nix { inherit pkgs; };
}
