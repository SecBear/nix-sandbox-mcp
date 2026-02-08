# Package the sandbox agent as a Nix derivation.
#
# The agent is a Python script that runs inside the jail as a long-lived
# process, maintaining interpreter state across executions.
{ pkgs }:

pkgs.writeScriptBin "sandbox-agent" ''
  #!${pkgs.python3}/bin/python3
  ${builtins.readFile ./sandbox_agent.py}
''
