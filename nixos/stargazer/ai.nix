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
    # Hardware Override for Radeon 890M (gfx1150) -> gfx1100
    rocmOverrideGfx = "11.0.0";

    loadModels = [
      "qwen2.5-coder:32b"
    ];

    environmentVariables = {
      OLLAMA_NUM_CTX = "32768";
      OLLAMA_KEEP_ALIVE = "24h";
    };
  };

  environment.systemPackages = with pkgs; [
    # Monitoring & Support
    rocmPackages.rocm-smi
    radeontop
  ];

}
