# WhisperX batch transcription + (optional) speaker diarization, as a watch-folder service.
# A shared, host-agnostic profile enabled with `custom.profiles.whisperx.enable = true`.
#
# This is the heavyweight, OFFLINE counterpart to the real-time Wyoming voice assistant
# (see homeassistant.nix): WhisperX pulls in torch + faster-whisper + pyannote and large
# Whisper/alignment/diarization models, so it is deliberately gated behind NVMe storage —
# its model cache lives under /var/cache, which hosts/rk1/nvme.nix parks on the NVMe drive.
#
# How it works (no network API, no auth surface):
#   - drop audio file(s) into   <dataDir>/inbox/
#   - a path unit notices and runs whisperx (CPU, int8) on each file
#   - transcripts (srt/vtt/txt/tsv/json) appear in <dataDir>/out/
#   - the source moves to <dataDir>/done/ (or <dataDir>/failed/ on error)
# Copy files in atomically (write a temp name, then rename into inbox) so the watcher never
# trips on a half-written upload; the watcher ignores dotfiles and *.part/*.tmp.
#
# The job runs at low CPU/IO priority (Nice/CPUWeight/IOSchedulingClass=idle) so a long
# transcription never makes the co-located Home Assistant voice pipeline lag — voice latency
# wins, batch transcription yields.
#
# Diarization (speaker labels) is opt-in: it needs a HuggingFace token with the gated
# pyannote models accepted. Set `diarize = true` and `hfTokenFile` to a secret holding the
# raw token (e.g. a sops secret readable by the whisperx user). Left off, transcription +
# word-level alignment still work with no token.
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.custom.profiles.whisperx;

  models = "${cfg.dataDir}/models";

  # Emitted only when diarization is enabled, so the rendered script never contains a constant
  # `[ "0" = "1" ]` (shellcheck SC2050). diarize_args is always declared below regardless.
  diarizeSetup = lib.optionalString cfg.diarize ''
    if [ -n "''${WX_HF_TOKEN_FILE:-}" ] && [ -r "''${WX_HF_TOKEN_FILE:-}" ]; then
      HF_TOKEN="$(tr -d '\n' < "$WX_HF_TOKEN_FILE")"
      export HF_TOKEN HUGGING_FACE_HUB_TOKEN="$HF_TOKEN"
      diarize_args+=(--diarize)
    else
      echo "whisperx: diarize enabled but HF token file unreadable; transcribing without speaker labels" >&2
    fi
  '';

  # The batch worker: drain the inbox, transcribe each file, file the source under done/failed.
  worker = pkgs.writeShellApplication {
    name = "whisperx-batch";
    runtimeInputs = [
      pkgs.python3Packages.whisperx
      pkgs.ffmpeg-headless
    ];
    text = ''
      inbox="${cfg.dataDir}/inbox"
      out="${cfg.dataDir}/out"
      done_dir="${cfg.dataDir}/done"
      failed="${cfg.dataDir}/failed"

      diarize_args=()
      ${diarizeSetup}
      found=0
      shopt -s nullglob
      for f in "$inbox"/*; do
        [ -f "$f" ] || continue
        case "$f" in
          */.* | *.part | *.tmp) continue ;;  # skip dotfiles and in-flight uploads
        esac
        found=1
        base="$(basename "$f")"
        echo "whisperx: transcribing $base"
        if whisperx "$f" \
            --model "${cfg.model}" \
            --model_dir "${models}/whisper" \
            --device cpu \
            --compute_type "${cfg.computeType}" \
            --threads "${toString cfg.threads}" \
            --batch_size "${toString cfg.batchSize}" \
            --language "${cfg.language}" \
            --output_dir "$out" \
            --output_format all \
            "''${diarize_args[@]}"; then
          mv -f "$f" "$done_dir/$base"
          echo "whisperx: done $base"
        else
          echo "whisperx: FAILED $base" >&2
          mv -f "$f" "$failed/$base" || true
        fi
      done
      [ "$found" = 1 ] || echo "whisperx: inbox empty, nothing to do"
    '';
  };
in
{
  options.custom.profiles.whisperx = {
    enable = lib.mkEnableOption "WhisperX batch transcription/diarization watch-folder (needs NVMe-backed /var/cache)";

    model = lib.mkOption {
      type = lib.types.str;
      default = "large-v3";
      description = "Whisper model name. large-v3 is the quality pick the NVMe makes room for; drop to medium/small if RAM/time is tight.";
    };

    language = lib.mkOption {
      type = lib.types.str;
      default = "en";
      description = "Source language code passed to whisperx (skips autodetect).";
    };

    computeType = lib.mkOption {
      type = lib.types.enum [
        "int8"
        "float32"
        "float16"
        "default"
      ];
      default = "int8";
      description = "faster-whisper compute type. int8 is the CPU pick (no GPU on these nodes).";
    };

    threads = lib.mkOption {
      type = lib.types.int;
      default = 4;
      description = "CPU threads for inference. 4 = the RK3588 A76 big cores.";
    };

    batchSize = lib.mkOption {
      type = lib.types.int;
      default = 8;
      description = "WhisperX batched-inference batch size.";
    };

    dataDir = lib.mkOption {
      type = lib.types.str;
      default = "/var/cache/whisperx";
      description = ''
        Root for the model cache and the inbox/out/done/failed work dirs. Defaults under
        /var/cache so it lands on the NVMe (hosts/rk1/nvme.nix mounts the drive there).
      '';
    };

    diarize = lib.mkEnableOption ''
      speaker diarization (pyannote). Requires `hfTokenFile`; without it, transcription +
      word alignment still run
    '';

    hfTokenFile = lib.mkOption {
      type = lib.types.nullOr lib.types.path;
      default = null;
      example = "/run/secrets/hf-token";
      description = ''
        Path to a file holding a HuggingFace token (raw token, no `HF_TOKEN=` prefix) with the
        gated pyannote diarization models accepted. Must be readable by the whisperx user.
      '';
    };

    user = lib.mkOption {
      type = lib.types.str;
      default = "whisperx";
      description = "System user the transcription job runs as.";
    };
  };

  config = lib.mkIf cfg.enable {
    assertions = [
      {
        assertion = !cfg.diarize || cfg.hfTokenFile != null;
        message = "custom.profiles.whisperx: diarize = true requires hfTokenFile (a HuggingFace token with pyannote models accepted).";
      }
    ];

    users.users.${cfg.user} = {
      isSystemUser = true;
      group = cfg.user;
      home = cfg.dataDir;
      createHome = false;
    };
    users.groups.${cfg.user} = { };

    # Work dirs on the NVMe-backed /var/cache. inbox is sticky+world-writable so any local
    # user can drop files (scp); only the file owner or whisperx (dir owner) can remove them,
    # so the worker can still file processed audio into done/.
    systemd.tmpfiles.rules = [
      "d ${cfg.dataDir}        0755 ${cfg.user} ${cfg.user} -"
      "d ${models}            0750 ${cfg.user} ${cfg.user} -"
      "d ${cfg.dataDir}/inbox  1777 ${cfg.user} ${cfg.user} -"
      "d ${cfg.dataDir}/out    0755 ${cfg.user} ${cfg.user} -"
      "d ${cfg.dataDir}/done   0755 ${cfg.user} ${cfg.user} -"
      "d ${cfg.dataDir}/failed 0755 ${cfg.user} ${cfg.user} -"
    ];

    # Oneshot worker: drains the inbox once, triggered by the .path unit below.
    systemd.services.whisperx-batch = {
      description = "WhisperX batch transcription (drain inbox)";
      # No start rate-limit: each drained file (and the dir change from moving it out) can
      # trigger the path unit, and a batch of drops triggers several times in quick succession.
      # The worker is idempotent and cheap on an empty inbox, so never let a burst fail the unit
      # (the old PathExistsGlob trigger looped on in-flight *.part files and hit start-limit).
      startLimitIntervalSec = 0;
      # Don't run before the model-cache disk is mounted (NVMe at /var/cache).
      unitConfig.RequiresMountsFor = [ "/var/cache" ];
      environment = {
        HOME = cfg.dataDir;
        HF_HOME = "${models}/huggingface";
        TORCH_HOME = "${models}/torch";
        XDG_CACHE_HOME = "${models}/xdg";
        NUMBA_CACHE_DIR = "${models}/numba";
        MPLCONFIGDIR = "${models}/mpl";
        OMP_NUM_THREADS = toString cfg.threads;
        WX_HF_TOKEN_FILE = lib.optionalString (cfg.hfTokenFile != null) (toString cfg.hfTokenFile);
      };
      serviceConfig = {
        Type = "oneshot";
        User = cfg.user;
        Group = cfg.user;
        ExecStart = lib.getExe worker;
        TimeoutStartSec = "6h";
        # Yield to the real-time voice pipeline: low scheduling priority, idle I/O.
        Nice = 15;
        CPUWeight = 20;
        IOWeight = 20;
        IOSchedulingClass = "idle";
        # Mild hardening: the only writable area is the data dir; needs network for model pulls.
        NoNewPrivileges = true;
        ProtectSystem = "strict";
        ProtectHome = true;
        PrivateTmp = true;
        ReadWritePaths = [ cfg.dataDir ];
      };
    };

    # Trigger on directory *changes*, not persistent existence. PathExistsGlob would re-fire in a
    # tight loop while an in-flight *.part upload (which the worker skips) still exists, tripping
    # the start-limit. PathChanged fires once per add/rename/remove in the inbox: a .part create
    # fires (worker skips), the rename to the final name fires (worker processes + moves it out),
    # and the move-out fires one last empty run — all bounded. Drop files atomically (write .part,
    # then rename in) so the worker never sees a half-written upload. Files already present when
    # the watcher (re)starts aren't seen by PathChanged — run `systemctl start whisperx-batch` to
    # drain those.
    systemd.paths.whisperx-batch = {
      description = "Watch the WhisperX inbox for new audio";
      wantedBy = [ "multi-user.target" ];
      pathConfig = {
        PathChanged = "${cfg.dataDir}/inbox";
        Unit = "whisperx-batch.service";
      };
    };
  };
}
