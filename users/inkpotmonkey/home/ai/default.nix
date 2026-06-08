{
  pkgs,
  config,
  inputs,
  lib,
  self,
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

      inputs.llm-agents.packages.${pkgs.stdenv.hostPlatform.system}.eca
      inputs.llm-agents.packages.${pkgs.stdenv.hostPlatform.system}.cursor-agent
      inputs.llm-agents.packages.${pkgs.stdenv.hostPlatform.system}.claude-code
      inputs.llm-agents.packages.${pkgs.stdenv.hostPlatform.system}.gemini-cli
      inputs.llm-agents.packages.${pkgs.stdenv.hostPlatform.system}.sandbox-runtime
      inputs.llm-agents.packages.${pkgs.stdenv.hostPlatform.system}.agent-browser
      inputs.llm-agents.packages.${pkgs.stdenv.hostPlatform.system}.mcporter

      # Skills CLI
      inputs.llm-agents.packages.${pkgs.stdenv.hostPlatform.system}.skills

      # Context Hub (chub)
      inputs.llm-agents.packages.${pkgs.stdenv.hostPlatform.system}.context-hub

      # MCP-NixOS — query NixOS packages, options, and more via MCP
      pkgs.mcp-nixos

      # Rust MCP — cargo build, test, clippy, add deps via agent
      # pkgs.rust-mcp-server

      nodejs

      playwright-driver.browsers

      ripgrep
      fd
      jq
      tree
    ];

    home.sessionVariables = {
      PLAYWRIGHT_BROWSERS_PATH = "${pkgs.playwright-driver.browsers}";
      PLAYWRIGHT_SKIP_BROWSER_DOWNLOAD = "1";
      PLAYWRIGHT_NODEJS_PATH = "${pkgs.nodejs}/bin/node";
      PLAYWRIGHT_SKIP_VALIDATE_HOST_REQUIREMENTS = "true";
    };

    sops = {
      defaultSopsFile = self.lib.getSecretPath "users/inkpotmonkey.yaml";
      defaultSopsFormat = "yaml";

      secrets.litellm_key = {
        key = "litellm-key";
      };
      secrets.exa = {
        key = "exa";
      };
      secrets.github_token = {
        key = "github_token";
      };

      templates."eca-config" = {
        content = (import ./eca.nix { inherit config self pkgs; }).configString;
        path = "${config.home.homeDirectory}/.config/eca/config.json";
      };
    };
  };
}
