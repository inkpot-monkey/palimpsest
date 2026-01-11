{
  rustPlatform,
  fetchFromGitHub,
  fetchurl,
  pkg-config,
  clang,
  cmake,
  git,
  onnxruntime,
  espeak-ng,
  alsa-lib,
  openssl,
  libopus,
  stdenv,
  writeShellScriptBin,
  libclang,
  makeBinaryWrapper,
  # Configuration
  model ? "v1.0",
  onnxName ? "kokoro-${model}.onnx",
  voicesName ? "voices-${model}.bin",
  onnxHash ? "sha256-fV347PfUsYeAFaMmhgU/0O6+K8N3I0YIdkzA7zY2psU=",
  voicesHash ? "sha256-vKYQuDCOjZnzLm/kGX5+wBZ5Jk7+0MrJFA/pwp8fv30=",
}:

let
  # Sonic Speech Library source for offline build
  sonicSrc = fetchFromGitHub {
    owner = "waywardgeek";
    repo = "sonic";
    rev = "master";
    hash = "sha256-/AHkv7F7SH/BbQy6HFnaIj7znKbljLGwwnJ1HPv9k3A=";
  };

  # Wrapped CMake to force flags during configuration
  cmakeWrapped = writeShellScriptBin "cmake" ''
    IS_BUILD=0
    for arg in "$@"; do
      if [[ "$arg" == "--build" || "$arg" == "--install" ]]; then
        IS_BUILD=1
        break
      fi
    done

    if [[ "$IS_BUILD" -eq 1 ]]; then
      exec ${cmake}/bin/cmake "$@"
    else
      exec ${cmake}/bin/cmake \
        -DCMAKE_POLICY_VERSION_MINIMUM=3.5 \
        -DFETCHCONTENT_SOURCE_DIR_SONIC-GIT=${sonicSrc} \
        -DFETCHCONTENT_FULLY_DISCONNECTED=ON \
        "$@"
    fi
  '';

  # Base URL for model files
  baseUrl = "https://github.com/thewh1teagle/kokoro-onnx/releases/download/model-files-${model}";

  modelOnnx = fetchurl {
    url = "${baseUrl}/${onnxName}";
    hash = onnxHash;
  };

  modelVoices = fetchurl {
    url = "${baseUrl}/${voicesName}";
    hash = voicesHash;
  };

  # Kokoro-Rust: Candle-based TTS engine
  kokorosPkg = rustPlatform.buildRustPackage {
    pname = "kokoros";
    version = "unstable-2025-01-10";

    src = fetchFromGitHub {
      owner = "lucasjinreal";
      repo = "Kokoros";
      rev = "main";
      hash = "sha256-0Ig5g8MTyZwRHOdUzOZBo6ebgVtBXbTezdKyWh9AVK0=";
    };

    cargoHash = "sha256-SvhHAfvF/jGmq4kybWDTbYamfEQSgnVI81RDLgGD1pY=";
    doCheck = false;

    nativeBuildInputs = [
      pkg-config
      clang
      cmakeWrapped # Use wrapped cmake
      git
    ];

    buildInputs = [
      onnxruntime
      espeak-ng
      alsa-lib
      openssl
      libopus
    ];

    env = {
      ORT_STRATEGY = "system";
      LIBCLANG_PATH = "${libclang.lib}/lib";
    };

    preBuild = ''
      # Verify pkg-config finds opus
      ${pkg-config}/bin/pkg-config --modversion opus || echo "pkg-config failed to find opus"
    '';
  };

in
stdenv.mkDerivation {
  pname = "kokoros";
  version = "1.0";

  nativeBuildInputs = [ makeBinaryWrapper ];

  unpackPhase = "true";

  installPhase = ''
    mkdir -p $out/bin
    # Copy or symlink the original binary
    ln -s ${kokorosPkg}/bin/koko $out/bin/koko

    # Wrap it to supply the model/data paths by default
    # This keeps the binary name 'koko' but ensures it works out of the box
    wrapProgram $out/bin/koko \
      --set ESPEAK_DATA_PATH "${espeak-ng}/share/espeak-ng-data" \
      --add-flags "--model ${modelOnnx} --data ${modelVoices}"
  '';
}
