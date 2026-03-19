{
  config,
  pkgs,
  lib,
  ...
}:

with lib;

let
  cfg = config.services.transcription-node;

  # Pinned to Nixpkgs commit 5720aa5c2cf5df0bd548e8522c543e321df917b5 (Hydra Build 322063957)
  pinnedPkgs =
    import
      (builtins.fetchTarball {
        url = "https://github.com/NixOS/nixpkgs/archive/5720aa5c2cf5df0bd548e8522c543e321df917b5.tar.gz";
        sha256 = "sha256:1c4jv3p4fkraag15y39rd38n15xrdknx6r6vnnp7j66a307g84pp";
      })
      {
        inherit (pkgs) system;
        config.allowUnfree = true;
      };

  whisperJail = pkgs.writeShellApplication {
    name = "whisper-jail";
    runtimeInputs = [ pinnedPkgs.whisperx ];
    text = ''
      set -e
      # PrivateTmp provides a fresh /tmp per connection
      TMP_AUDIO="/tmp/audio.ogg"

      # Read the binary stream from the systemd socket (stdin)
      cat > "$TMP_AUDIO"

      # Execute inference using the specified model
      whisperx "$TMP_AUDIO" \
          --model ${cfg.model} \
          --language ${cfg.language} \
          --compute_type int8 \
          --output_format srt \
          --output_dir /tmp > /dev/null 2>&1

      # Stream the result back to the socket (stdout)
      if [ -f "/tmp/audio.srt" ]; then
        cat /tmp/audio.srt
      fi
    '';
  };
in
{
  options.services.transcription-node = {
    enable = mkEnableOption "Transcription Service";

    listenAddress = mkOption {
      type = types.str;
      description = "The Tailscale IP address to listen on.";
    };

    port = mkOption {
      type = types.port;
      default = 9999;
    };

    model = mkOption {
      type = types.str;
      default = "large-v3";
    };

    language = mkOption {
      type = types.str;
      default = "es";
    };
  };

  config = mkIf cfg.enable {
    # Create the restricted user
    users.users.transcription-node = {
      isNormalUser = true;
      description = "Restricted AI Execution Node";
    };

    # The Network Listener
    systemd.sockets."whisper-api" = {
      description = "WhisperX Socket Listener";
      listenStreams = [ "${cfg.listenAddress}:${toString cfg.port}" ];
      wantedBy = [ "sockets.target" ];
      socketConfig.Accept = true;
    };

    # The Service Instance (Template)
    systemd.services."whisper-api@" = {
      description = "WhisperX Inference Instance";
      serviceConfig = {
        ExecStart = "${whisperJail}/bin/whisper-jail";
        User = "transcription-node";
        StandardInput = "socket";
        StandardOutput = "socket";
        StandardError = "journal";

        CPUWeight = 20;
        MemoryMax = "8G";

        # Hardening
        PrivateTmp = true;
        ProtectSystem = "strict";
        ProtectHome = "tmpfs";
        NoNewPrivileges = true;
        RestrictRealtime = true;
      };
    };
  };
}
