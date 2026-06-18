{
  pkgs,
  ...
}:
let
  visionModel = "qwen2.5vl:3b";
  codingModel = "qwen2.5-coder:14b";
in
{
  services.ollama = {
    enable = true;
    package = pkgs.ollama-rocm;
    loadModels = [
      codingModel
      visionModel
    ];
    syncModels = true;
  };

  environment.sessionVariables = {
    OLLAMA_VISION_MODEL = visionModel;
  };

  # WhisperX batch transcription/diarization CLI, driven from Emacs/dired (see
  # users/inkpotmonkey/home/emacs/lisp/whisperx.el). No watch-folder service — just the tool
  # on PATH, run on the Zen 5 CPU (CTranslate2 int8). ffmpeg-full handles video containers.
  environment.systemPackages = [
    pkgs.python3Packages.whisperx
    pkgs.ffmpeg-full
  ];

  hardware.amdgpu.opencl.enable = true;
  hardware.amdgpu.initrd.enable = true;

  services.lact.enable = true;

  systemd.tmpfiles.rules =
    let
      rocmEnv = pkgs.symlinkJoin {
        name = "rocm-combined";
        paths = with pkgs.rocmPackages; [
          clr
          hipblas
          rocblas
        ];
      };
    in
    [ "L+ /opt/rocm - - - - ${rocmEnv}" ];
}
