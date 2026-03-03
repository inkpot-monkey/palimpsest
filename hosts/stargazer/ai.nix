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
