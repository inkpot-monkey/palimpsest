{
  pkgs,
  ...
}:

{
  imports = [
  ];

  # 1. Ollama (The Brain)
  services.ollama = {
    enable = true;
    package = pkgs.ollama-rocm;
    # Hardware Override for Radeon 890M
    # 11.5.0 crashed (invalid device function), reverting to 11.0.0.
    # Must use BIOS/Kernel settings to fix the VRAM report.
    rocmOverrideGfx = "11.0.0";

    loadModels = [
      "qwen2.5-coder:14b"
    ];

    environmentVariables = {
      OLLAMA_CONTEXT_LENGTH = "16384"; # Increased to handle Goose system prompt (~10k)
      OLLAMA_KEEP_ALIVE = "24h";
      HSA_ENABLE_SDMA = "0"; # often helps with APU glitches
    };
  };

  environment.systemPackages = with pkgs; [
    # Monitoring & Support
    rocmPackages.rocm-smi
    radeontop
  ];

}
