{
  inputs,
  self,
  pkgs,
  ...
}:

{
  imports = [
    inputs.sops-nix.homeManagerModule
    # The sops binding for the contract platform interface (ADR-0021): realizes
    # custom.platform.secrets onto sops here, so feature modules never name sops.*.
    self.homeManagerModules.platformSops

    ./base.nix
    ./shell.nix
    ./git.nix
    ./ssh.nix
  ];

  # Claude Code on every CLI host (incl. headless servers like kelpy). The AionUi
  # backend discovers and spawns the `claude` CLI from $PATH, and this also lets
  # you `claude login` / use it directly over SSH. (rg/fd/jq/git come from
  # ./shell.nix and ./git.nix.)
  home.packages = [
    inputs.llm-agents.packages.${pkgs.stdenv.hostPlatform.system}.claude-code
    pkgs.nodejs
  ];
}
