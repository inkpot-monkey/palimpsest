{
  pkgs,
  config,
  inputs,
  lib,
  ...
}:
{
  options.custom.home.profiles.ai = {
    enable = lib.mkEnableOption "AI tools and configurations";
  };

  imports = [
    inputs.self.homeManagerModules.kokoro-tts
  ];

  config = lib.mkIf config.custom.home.profiles.ai.enable {
    home.packages = with pkgs; [
      antigravity
      inputs.llm-agents.packages.${pkgs.stdenv.hostPlatform.system}.cursor-agent
      inputs.llm-agents.packages.${pkgs.stdenv.hostPlatform.system}.gemini-cli

      mcp-nixos
    ];
  };
}
