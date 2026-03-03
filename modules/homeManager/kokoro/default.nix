{
  config,
  pkgs,
  lib,
  ...
}:

with lib;

let
  cfg = config.services.kokoro-tts;

  # --- 1. Internal Mappings (Hidden from User) ---
  # We use these only for fallbacks if the user requests a language
  # they haven't explicitly configured a voice for.
  isoToKokoro = {
    "en-us" = "a";
    "en" = "a";
    "en-gb" = "b";
    "en-uk" = "b";
    "es" = "e";
    "es-es" = "e";
    "es-mx" = "e";
    "fr-fr" = "f";
    "fr" = "f";
    "ja" = "j";
    "jp" = "j";
    "zh" = "z";
    "cn" = "z";
    "it" = "i";
    "pt-br" = "p";
    "pt" = "p";
  };

  # --- 2. Smart Logic: Determine Models to Load ---
  # We look at the voices the user selected (e.g., "bf_emma")
  # and automatically extract the first letter ("b") to know we need the British Model.
  # This removes the need for a manual "preLoadModels" option.
  configuredModels = unique (map (voice: substring 0 1 voice) (attrValues cfg.defaultVoices));

  # We always load 'a' and 'e' as safe defaults unless the user wipes the config,
  # plus whatever specific voices the user added.
  finalModelsToLoad = unique (
    configuredModels
    ++ [
      "a"
      "e"
    ]
  );

  # Generate Python code to load these models
  preloadLines = concatMapStringsSep "\n    " (
    code: "pipelines['${code}'] = KPipeline(lang_code='${code}')"
  ) finalModelsToLoad;

  # --- 3. Python Environment ---
  pythonEnv = pkgs.python3.withPackages (
    ps: with ps; [
      kokoro
      fastapi
      uvicorn
      soundfile
      requests
    ]
  );

  # Inject configs into Python
  userVoicesJson = generators.toJSON { } cfg.defaultVoices;
  isoMapJson = generators.toJSON { } isoToKokoro;

  # --- 4. The Server Script ---
  serverScript = pkgs.writeScriptBin "kokoro-server" ''
    #!${pythonEnv}/bin/python3
    import uvicorn
    import io
    import soundfile as sf
    from fastapi import FastAPI, Response, Body, HTTPException
    from kokoro import KPipeline

    app = FastAPI()

    # Injected Configs
    USER_VOICES = ${userVoicesJson}
    ISO_MAP = ${isoMapJson}

    # Hardcoded Factory Fallbacks (Used only if config is missing)
    FACTORY_DEFAULTS = {
        'a': 'af_heart', 'b': 'bf_emma', 'e': 'ef_dora',
        'f': 'ff_siwis', 'j': 'jf_alpha', 'z': 'zf_xiaobei',
        'i': 'if_sara',  'p': 'pm_alex'
    }

    print(f"Loading Models: {list(set([v[0] for v in USER_VOICES.values()]))}")
    pipelines = {}

    try:
      ${preloadLines}
    except Exception as e:
      print(f"Error loading models: {e}")

    @app.post("/speak")
    async def speak(
        text: str = Body(..., embed=True), 
        voice: str = Body(None, embed=True), 
        lang: str = Body("en-us", embed=True),
        speed: float = Body(1.0, embed=True)
    ):
        # 1. Normalize Language Input
        clean_lang = lang.lower().replace("_", "-") # "en_US" -> "en-us"
        base_lang = clean_lang.split("-")[0]        # "en-us" -> "en"

        # 2. Determine Voice & Pipeline Code
        # This is the "Smart" logic: derived entirely from the voice ID.
        
        target_voice = voice
        pipeline_code = None

        if not target_voice:
            # A. Check User Config for Exact Match (e.g. "es-mx")
            target_voice = USER_VOICES.get(clean_lang)
            
            # B. Check User Config for Base Match (e.g. "es")
            if not target_voice:
                target_voice = USER_VOICES.get(base_lang)
        
        # 3. Resolve Pipeline from Voice
        if target_voice:
            # Trust the voice ID (e.g. "bf_emma" -> starts with 'b' -> British)
            pipeline_code = target_voice[0]
        else:
            # C. Fallback: User didn't configure this language at all.
            # Try to guess code from ISO map and use factory default voice.
            pipeline_code = ISO_MAP.get(clean_lang, ISO_MAP.get(base_lang, 'a'))
            target_voice = FACTORY_DEFAULTS.get(pipeline_code, "af_heart")
            print(f"Warning: No voice configured for '{lang}'. Using fallback '{target_voice}'.")

        # 4. Check if Model is Loaded
        if pipeline_code not in pipelines:
             raise HTTPException(status_code=400, detail=f"Model for '{lang}' (Code: {pipeline_code}) is not loaded. Add a voice for this language in your Nix config.")

        # 5. Generate
        generator = pipelines[pipeline_code](text, voice=target_voice, speed=speed, split_pattern=r"\n+")
        
        all_audio = []
        for i, (gs, ps, audio) in enumerate(generator):
            if audio is not None:
                all_audio.extend(audio)
        
        buffer = io.BytesIO()
        sf.write(buffer, all_audio, 24000, format="WAV")
        buffer.seek(0)
        
        return Response(content=buffer.read(), media_type="audio/wav")

    if __name__ == "__main__":
        uvicorn.run(app, host="127.0.0.1", port=${toString cfg.port})
  '';

  # --- 5. The Client Script ---
  clientScript = pkgs.writeScriptBin "kokoro-client" ''
    #!${pythonEnv}/bin/python3
    import sys
    import requests
    import subprocess

    text = sys.stdin.read().strip()
    if not text: sys.exit(0)

    try:
        # We send only text and lang. We let the server pick the configured voice.
        # Defaults to en-us if Speech Dispatcher doesn't specify.
        response = requests.post(
            "http://127.0.0.1:${toString cfg.port}/speak", 
            json={"text": text, "lang": "en-us"},
            timeout=15
        )
        response.raise_for_status()
        
        process = subprocess.Popen(
            ["${pkgs.pulseaudio}/bin/paplay", "--property=media.role=phone"], 
            stdin=subprocess.PIPE
        )
        process.communicate(input=response.content)
    except Exception as e:
        sys.stderr.write(f"Kokoro Error: {e}\n")
  '';

in
{
  options.services.kokoro-tts = {
    enable = mkEnableOption "Kokoro TTS Local Service";

    port = mkOption {
      type = types.port;
      default = 8880;
      description = "Port for the local API.";
    };

    defaultVoices = mkOption {
      type = types.attrsOf types.str;
      default = {
        "en-us" = "af_heart";
        "es" = "ef_dora";
      };
      description = ''
        Map languages to specific Voice IDs. 
        The system automatically loads the correct model based on the voice you choose.

        Examples:
        - "en": "bf_emma"    -> Sets generic English to British.
        - "es-mx": "em_alex" -> Sets Mexican Spanish to Alex.
        - "fr": "ff_siwis"   -> Adds French support.
      '';
    };
  };

  config = mkIf cfg.enable {
    systemd.user.services.kokoro-tts = {
      Unit = {
        Description = "Kokoro TTS Local Server";
        After = [
          "network.target"
          "sound.target"
        ];
      };
      Service = {
        ExecStart = "${serverScript}/bin/kokoro-server";
        Restart = "always";
        Environment = "HF_HOME=%h/.cache/huggingface";
      };
      Install = {
        WantedBy = [ "default.target" ];
      };
    };

    # Speech Dispatcher Integration
    xdg.configFile."speech-dispatcher/modules/kokoro.conf".text = ''
      Debug 0
      GenericExecuteSynth "echo \'$DATA\' | ${clientScript}/bin/kokoro-client"
    '';

    xdg.configFile."speech-dispatcher/speechd.conf".text = ''
      AddModule "kokoro" "sd_generic" "kokoro.conf"
      DefaultModule kokoro
    '';

    home.packages = [
      serverScript
      clientScript
      pkgs.speechd
    ];
  };
}
