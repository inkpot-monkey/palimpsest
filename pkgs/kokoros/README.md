# Kokoros (Nix Package)

A straightforward Nix package for [Kokoros](https://github.com/lucasjinreal/Kokoros), a high-quality, offline TTS engine based on Candle.

## Features
-   **Native Binary**: Provides the standard `koko` executable.
-   **Zero Configuration**: Model (`v1.0.onnx`) and Voices (`voices.bin`) are automatically injected via a binary wrapper.
-   **Runtime Ready**: Dependencies like `espeak-ng` data are correctly bundled.

## Usage

### Basic Text-to-Speech
Generate audio from text input:
```bash
koko text "Hello from NixOS!" -o output.wav
```

### Piping (Stream)
Pipe text from standard input:
```bash
echo "Streaming text generation..." | koko stream > output.wav
```

### Selecting Voices (`--style`)
Select a specific voice style. **Note: `--style` must be placed BEFORE the `text` subcommand.**

```bash
# American Female (Bella) - Default is similar
koko --style af_bella text "Hello there." -o voice.wav

# British Male (George)
koko --style bm_george text "Cheerio!" -o voice.wav
```

### Languages (`--lan`)
To get correct pronunciation for non-English languages, you **must** specify the language flag (default is `en-us`).

```bash
# Spanish
koko --lan es --style ef_dora text "Hola, cómo estás?" -o spanish.wav

# French
koko --lan fr --style ff_siwis text "Bonjour le monde." -o french.wav

# Italian
koko --lan it --style if_sara text "Ciao!" -o italian.wav
```

## Configuration

### Overriding the Model
The package defaults to **v1.0** (High Quality). You can override the version and hashes to use other models (e.g., `v1.1` for Chinese support). The package dynamically constructs URLs based on the model version.

**In `configuration.nix`:**
```nix
environment.systemPackages = [
  (pkgs.kokoros.override {
    # Example: Switching to v1.1 (Chinese)
    model = "v1.1";
    onnxName = "kokoro-v1.1-zh.onnx";
    voicesName = "voices-v1.1-zh.bin";
    onnxHash = "sha256-7v7HCMvHq6joEptcL3y5Lh/n0oGvHh3UUVktn/BxSg0=";
    voicesHash = "sha256-FMthhsmeT2AWhxQF9iBGxd+GOuJ0ZcvcTuCL591wOs0=";
  })
];
```

## Available Voices (v1.0)
*   **US Female**: `af_bella`, `af_sarah`, `af_heart`, `af_nicole`, `af_sky`, `af_alloy`, `af_jessica`, `af_kore`, `af_nova`, `af_river`, `af_aoede`
*   **US Male**: `am_adam`, `am_michael`, `am_echo`, `am_liam`, `am_onyx`, `am_puck`, `am_eric`, `am_fenrir`, `am_santa`
*   **GB Female**: `bf_emma`, `bf_isabella`, `bf_alice`, `bf_lily`
*   **GB Male**: `bm_george`, `bm_lewis`, `bm_daniel`, `bm_fable`
*   **Spanish**: `ef_dora` (Female), `em_alex`, `em_santa` (Male)
*   **French**: `ff_siwis`
*   **Italian**: `if_sara`, `im_nicola`
*   **Japanese**: `jf_alpha`, `jf_gongitsune`, `jf_nezumi`, `jf_tebukuro`, `jm_kumo`
*   **Mandarin**: `zf_xiaobei`, `zf_xiaoni`, `zf_xiaoxiao`, `zf_xiaoyi`, `zm_yunjian`, `zm_yunxi`, `zm_yunxia`, `zm_yunyang`
