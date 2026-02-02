# Node.js environment for JavaScript execution
{ pkgs }:

pkgs.buildEnv {
  name = "sandbox-env-node";
  paths = with pkgs; [
    nodejs
    coreutils
  ];
}
