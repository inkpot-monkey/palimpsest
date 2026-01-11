{ config, lib, pkgs, ... }:

let
  # Kokoro-Rust: Candle-based TTS engine
  kokoros = pkgs.rustPlatform.buildRustPackage {
    pname = "kokoros";
    version = "unstable-2025-01-10";

    src = pkgs.fetchFromGitHub {
      owner = "lucasjinreal";
      repo = "Kokoros";
      rev = "main";
      hash = lib.fakeHash; # FIXME: Replace with actual hash after first build attempt
    };

    cargoHash = lib.fakeHash; # FIXME: Replace with actual cargoHash

    nativeBuildInputs = with pkgs; [
      pkg-config
      clang
      cmake
      git
    ];

    buildInputs = with pkgs; [
      onnxruntime
      espeak-ng
      alsa-lib
      openssl
    ];

    env = {
      ORT_STRATEGY = "system";
      LIBCLANG_PATH = "${pkgs.libclang.lib}/lib";
    };
  };

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
  # 1. Ollama (The Brain)
  services.ollama = {
    enable = true;
    acceleration = "rocm";
    # Hardware Override for Radeon 890M (gfx1150) -> gfx1100
    rocmOverrideGfx = "11.0.0"; 
    
    loadModels = [
      "qwen2.5-coder:14b"
    ];
  };

  # 2. Kokoro (The Voice)
  environment.systemPackages = with pkgs; [
    kokoros # The custom package defined above
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
