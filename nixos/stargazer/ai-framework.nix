{ config, lib, pkgs, ... }:

let
  # Goose Configuration Template
  gooseConfig = {
    provider = "ollama";
    model = "qwen2.5-coder:14b";
    extensions = [
      "developer"
      "computercontroller"
      "memory"
    ];
    GOOSE_PROVIDER_OLLAMA_HOST = "http://localhost:11434";
  };
in
{
  imports = [
  ];

  # 1. Ollama (The Brain)
  services.ollama = {
    enable = true;
    package = pkgs.ollama-rocm;
    # Hardware Override for Radeon 890M (gfx1150) -> gfx1100
    rocmOverrideGfx = "11.0.0"; 
    
    loadModels = [
      "qwen2.5-coder:14b"
    ];
  };

  environment.systemPackages = with pkgs; [
    kokoros # Default config (v1.0 model)
    
    goose-cli # The Agent
    
    # Monitoring & Support
    rocmPackages.rocm-smi
    radeontop
  ];

  # 3. Goose (The Agent) - Secrets & Config
  sops.templates."goose-config.yaml" = {
    path = "/home/inkpotmonkey/.config/goose/config.yaml";
    owner = "inkpotmonkey"; # Assuming user implementation details
    content = ''
      provider: ${gooseConfig.provider}
      model: ${gooseConfig.model}
      extensions:
      ${lib.concatMapStrings (ext: "  - ${ext}\n") gooseConfig.extensions}
      
      # Secrets injected via sops-nix
      GITHUB_TOKEN: ${config.sops.placeholder.github_token}
    '';
  };
}
