{
  config,
  lib,
  pkgs,
  ...
}:

with lib;

let
  cfg = config.programs.goose;
in
{
  options.programs.goose = {
    enable = mkEnableOption "Goose AI Agent";

    package = mkOption {
      type = types.package;
      default = pkgs.goose-cli;
      description = "The goose-cli package to install.";
    };

    provider = mkOption {
      type = types.enum [
        "ollama"
        "openai"
        "anthropic"
        "databricks"
        "cursor-agent"
        "google"
        "gemini-cli"
      ];
      default = "ollama";
      description = " The AI provider to use.";
    };

    model = mkOption {
      type = types.str;
      default = "qwen2.5-coder:14b";
      description = "The model to use with the provider.";
    };

    ollamaHost = mkOption {
      type = types.str;
      default = "http://localhost:11434";
      description = "Host URL for Ollama (if used).";
    };

    extensions = mkOption {
      type = types.listOf types.str;
      default = [
        "developer"
        "computercontroller"
        "memory"
      ];
      description = "List of extensions to enable.";
    };
    mcpServers = mkOption {
      type = types.attrsOf (
        types.submodule {
          options = {
            command = mkOption { type = types.str; };
            args = mkOption {
              type = types.listOf types.str;
              default = [ ];
            };
            env = mkOption {
              type = types.attrsOf (types.either types.str types.attrs);
              default = { };
              description = "Environment variables to set for the MCP server. Supports string values or sops secret objects (which will be read via 'cat').";
            };
            type = mkOption {
              type = types.str;
              default = "stdio";
            };
          };
        }
      );
      default = { };
      description = "MCP servers to configure as extensions.";
    };

    env = mkOption {
      type = types.attrsOf (types.either types.str types.attrs);
      default = { };
      description = "Environment variables to set for the Goose main process. Supports string values or sops secret objects (which will be read via 'cat').";
    };

    profiles = mkOption {
      type = types.attrsOf (
        types.submodule {
          options = {
            provider = mkOption {
              type = types.nullOr types.str;
              default = null;
              description = "Override the provider for this profile.";
            };
            model = mkOption {
              type = types.nullOr types.str;
              default = null;
              description = "Override the model for this profile.";
            };
          };
        }
      );
      default = { };
      description = "Define additional Goose profiles (e.g. 'flash' -> 'goose-flash').";
    };
  };

  config = mkIf cfg.enable {
    home.packages =
      let
        # Common logic to inject environment variables
        envInjection = lib.concatStringsSep "\n" (
          lib.mapAttrsToList (
            k: v:
            if builtins.isAttrs v && v ? path then
              "export ${k}=$(cat ${v.path})"
            else
              "export ${k}=${toString v}"
          ) cfg.env
        );

        # Main Goose Wrapper
        gooseWrapped = pkgs.writeShellScriptBin "goose" ''
          ${envInjection}
          exec ${cfg.package}/bin/goose "$@"
        '';

        # Generate profile scripts (e.g. goose-flash)
        profileScripts = lib.mapAttrsToList (
          name: profile:
          pkgs.writeShellScriptBin "goose-${name}" ''
            ${envInjection}
            ${if profile.provider != null then "export GOOSE_PROVIDER=${profile.provider}" else ""}
            ${if profile.model != null then "export GOOSE_MODEL=${profile.model}" else ""}
            exec ${cfg.package}/bin/goose "$@"
          ''
        ) cfg.profiles;
      in
      [ gooseWrapped ] ++ profileScripts;

    xdg.configFile."goose/config.yaml".text = builtins.toJSON {
      GOOSE_PROVIDER = cfg.provider;
      GOOSE_MODEL = cfg.model;
      OLLAMA_HOST = cfg.ollamaHost;
      extensions =
        let
          # Convert mcpServers to Goose extension format with wrapper scripts
          mcpExtensions = lib.mapAttrs (
            name: server:
            let
              # Generate a wrapper script that sets env vars before running the server
              wrapper = pkgs.writeShellScript "goose-mcp-${name}" ''
                ${lib.concatStringsSep "\n" (
                  lib.mapAttrsToList (
                    k: v:
                    if builtins.isAttrs v && v ? path then
                      "export ${k}=$(cat ${v.path})"
                    else
                      "export ${k}=${toString v}"
                  ) server.env
                )}
                exec ${server.command} "$@"
              '';
            in
            {
              enabled = true;
              inherit name;
              inherit (server) type;
              cmd = "${wrapper}";
              inherit (server) args;
              env = { }; # Env is handled by wrapper
            }
          ) cfg.mcpServers;

          # Built-in extensions (enabled by default list)
          builtinExtensions = lib.genAttrs cfg.extensions (name: {
            enabled = true;
            inherit name;
            type = "builtin";
          });
        in
        builtinExtensions // mcpExtensions;
    };
  };
}
