{ config, pkgs, lib, ... }:

with lib;

let
  cfg = config.programs.finance;
  
  # Build the python package
  # Build the python package
  # Use the package from the overlay (pkgs.finance-tools) or fallback to direct path
  financePackage = pkgs.finance-tools or (pkgs.callPackage ../../../pkgs/finance-tools/package.nix { });
  
  # Create a python environment that includes fava and our module (so fava can find the extension)
  pythonEnv = pkgs.python3.withPackages (ps: [ financePackage ps.fava ]);

  # Helper to get the executable path
  financeExe = "${financePackage}/bin/finance-ingest-internal";

  # Setup environment variables for secrets
  # We reuse the logic from the user's request: check sops secrets or environment
  # But for the systemd service we can use EnvironmentFile.
  
  # Interactive wrapper that sources secrets
  # Now simplified as we don't need external secrets for Ollama
  financeWrapper = pkgs.writeShellScriptBin "finance-ingest" ''
    echo "Running finance-ingest from package..."
    
    # Delegate to the internal python script
    if [ $# -eq 0 ]; then
       echo "Running default ingestion..."
       ${financeExe} extract -e "${cfg.configDir}/main.bean" "${cfg.dataDir}/imports/"*.csv > "${cfg.dataDir}/new_entries.bean"
       echo "Done. Check ${cfg.dataDir}/new_entries.bean"
    else
       ${financeExe} "$@"
    fi
  '';

  # Manual script to pull the model (run once)
  modelInitScript = pkgs.writeShellScriptBin "finance-model-init" ''
    echo "Checking Ollama connection..."
    # Wait for Ollama to be ready
    until ${pkgs.curl}/bin/curl -s http://localhost:11434/api/tags > /dev/null; do
       echo "Waiting for Ollama..."
       sleep 2
    done
    
    echo "Pulling qwen2.5:7b..."
    ${config.services.ollama.package}/bin/ollama pull qwen2.5:7b
    echo "Done! Model is ready."
  '';

in
{
  options.programs.finance = {
    enable = mkEnableOption "Personal Finance System";
    
    dataDir = mkOption {
      type = types.path;
      default = "${config.home.homeDirectory}/finance";
      description = "Directory containing finance data (CSVs, etc).";
    };

    configDir = mkOption {
      type = types.path;
      default = cfg.dataDir; # Keep everything in one place (~/finance)
      defaultText = literalExpression "\${config.home.homeDirectory}/finance";
      description = "Directory containing configuration and main ledger file.";
    };
  };

  config = mkIf cfg.enable {
    # Expose the wrapper
    home.packages = [
      financeWrapper
      financePackage
      modelInitScript
    ];

    # Initialize main.bean if it doesn't exist (Mutable Copy Pattern)
    home.activation.createFinanceMainBean = lib.hm.dag.entryAfter ["writeBoundary"] ''
      if [ ! -f "${cfg.dataDir}/main.bean" ]; then
        echo "Initializing main.bean in ${cfg.dataDir}..."
        mkdir -p "${cfg.dataDir}"
        cat <<EOF > "${cfg.dataDir}/main.bean"
option "title" "Personal Finance"
option "operating_currency" "GBP"

2025-01-01 custom "fava-extension" "finance_extensions.sync_ext"
2025-01-01 custom "fava-extension" "finance_extensions.model_ext"

2025-01-01 custom "fava-option" "auto-reload" "true"
2025-01-01 custom "fava-option" "show-closed-accounts" "false"
2025-01-01 custom "fava-option" "currency-column" "60"
2025-01-01 custom "fava-option" "account-journal-include-children" "false"

include "new_entries.bean"
EOF
        chmod 644 "${cfg.dataDir}/main.bean"
      fi
    '';

    # Services
    # Enable Ollama
    services.ollama.enable = true;

    # Fava Service
    systemd.user.services.fava = {
      Unit = {
        Description = "Fava Web UI";
        After = [ "network.target" ];
      };

      Service = {
        ExecStart = "${pythonEnv}/bin/fava ${cfg.configDir}/main.bean";
        Environment = [ 
          "FINANCE_DATA_DIR=${cfg.dataDir}"
          "BEANCOUNT_FILE=${cfg.configDir}/main.bean"
          "FINANCE_INGEST_CMD=${financeWrapper}/bin/finance-ingest"
        ];
        Restart = "always";
        RestartSec = "10s";
      };

      Install = {
        WantedBy = [ "default.target" ];
      };
    };

    # Ingest Service
    systemd.user.services.finance-fetch = {
      Unit = {
        Description = "Finance Data Ingestion";
        After = [ "ollama.service" ]; # Wait for ollama to start, but don't block on model
      };

      Service = {
        Type = "oneshot";
        
        # Run the internal binary directly
        ExecStart = pkgs.writeShellScript "finance-fetch-run" ''
           ${financeExe} extract -e "${cfg.configDir}/main.bean" "${cfg.dataDir}/imports/"*.csv > "${cfg.dataDir}/new_entries.bean"
        '';
        
        Environment = "FINANCE_DATA_DIR=${cfg.dataDir}";
      };
    };

    # Timer
    systemd.user.timers.finance-fetch = {
      Unit = {
        Description = "Daily Timer for Finance Data Ingestion";
      };

      Timer = {
        OnCalendar = "daily";
        Persistent = true;
        Unit = "finance-fetch.service";
      };

      Install = {
        WantedBy = [ "timers.target" ];
      };
    };
  };
}
