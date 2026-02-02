# Minimal shell environment for bash script execution
{ pkgs }:

pkgs.buildEnv {
  name = "sandbox-env-shell";
  paths = with pkgs; [
    bash
    coreutils
    gnused
    gnugrep
    gawk
    findutils
  ];
}
