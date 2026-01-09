{
  pkgs,
  config,
  lib,
  ...
}:
{
  services.ollama = {
    enable = true;
    package = pkgs.ollama-rocm;
    # RDNA 3.5 / Radeon 890M override
    rocmOverrideGfx = "11.0.0";
    
    # Enable model loading service
    loadModels = [
      "deepseek-r1:32b"
      "qwen2.5-coder:32b"
    ];

    # Open firewall for local access if needed (optional, keeping consistent with plan)
    openFirewall = true;
  };
}
