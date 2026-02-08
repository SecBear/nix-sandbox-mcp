# Python 3 environment for script execution
{ pkgs }:

pkgs.buildEnv {
  name = "sandbox-env-python";
  paths = with pkgs; [
    (python3.withPackages (ps: [ ps.pyyaml ]))
    coreutils
  ];
}
