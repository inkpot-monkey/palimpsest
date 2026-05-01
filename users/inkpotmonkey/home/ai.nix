{
  pkgs,
  config,
  inputs,
  lib,
  self,
  ...
}:
let
  litellm = self.nixosConfigurations.kelpy.config.services.litellm;
in
{
  options.custom.home.profiles.ai = {
    enable = lib.mkEnableOption "AI tools and configurations";
  };

  imports = [
    inputs.self.homeManagerModules.kokoro-tts
  ];

  config = lib.mkIf config.custom.home.profiles.ai.enable {
    home.packages = with pkgs; [
      antigravity

      inputs.eca.packages.${pkgs.stdenv.hostPlatform.system}.eca
      inputs.llm-agents.packages.${pkgs.stdenv.hostPlatform.system}.cursor-agent
      inputs.llm-agents.packages.${pkgs.stdenv.hostPlatform.system}.gemini-cli
      inputs.llm-agents.packages.${pkgs.stdenv.hostPlatform.system}.sandbox-runtime
      inputs.llm-agents.packages.${pkgs.stdenv.hostPlatform.system}.agent-browser
      inputs.llm-agents.packages.${pkgs.stdenv.hostPlatform.system}.mcporter

      # Node.js / npx — required for MCP servers (Antigravity launches with a
      # minimal $PATH from the display manager and won't find npx otherwise)
      nodejs

      # mcp-nixos
      playwright-driver.browsers

      # Code search tools
      ripgrep
      fd
      jq

    ];

    home.sessionVariables = {
      PLAYWRIGHT_BROWSERS_PATH = "${pkgs.playwright-driver.browsers}";
      PLAYWRIGHT_SKIP_BROWSER_DOWNLOAD = "1";
    };

    sops = {
      defaultSopsFile = self.lib.getSecretPath "users/inkpotmonkey.yaml";
      defaultSopsFormat = "yaml";
      # Define the secret for Home Manager
      secrets.litellm_key = {
        key = "litellm-key";
      };
      secrets.exa = {
        key = "exa";
      };

      templates."eca-config" = {
        content =
          let
            # Map LiteLLM model names to a central set for easy referencing
            m = builtins.listToAttrs (
              map (m: {
                name = m.model_name;
                value = m.model_name;
              }) litellm.settings.model_list
            );

            # Map LiteLLM model list to ECA provider models
            litellmModels = builtins.listToAttrs (
              map (name: {
                inherit name;
                value = { };
              }) (builtins.attrNames m)
            );
          in

          builtins.toJSON {
            # customTools = {
            #   "code-search" = {
            #     description = "Search codebase content using ripgrep. Use this to search through project files for specific code patterns.";
            #     command = "rg --color=never --line-number --smart-case {{query}} {{directory}}";
            #     schema = {
            #       properties = {
            #         query = {
            #           type = "string";
            #           description = "Search pattern to find in the codebase";
            #         };
            #         directory = {
            #           type = "string";
            #           description = "Directory to search within (default: current directory)";
            #         };
            #         file_type = {
            #           type = "string";
            #           description = "File type filter (e.g., 'py', 'js', 'nix', 'rs')";
            #         };
            #       };
            #       required = [ "query" ];
            #     };
            #   };
            #   "find-files" = {
            #     description = "Find files by name or extension across the project. Use this when you know the file name but not its location.";
            #     command = "fd --type f --hidden --exclude .git --exclude node_modules {{pattern}} {{directory}}";
            #     schema = {
            #       properties = {
            #         pattern = {
            #           type = "string";
            #           description = "File name pattern (e.g., '*.ts', 'config.json', or 'auth')";
            #         };
            #         directory = {
            #           type = "string";
            #           description = "Directory to search within (default: .)";
            #         };
            #       };
            #       required = [ "pattern" ];
            #     };
            #   };
            #   "project-tree" = {
            #     description = "View the directory structure to understand project layout. Use this to orient yourself in the codebase. Always specify a low depth (like 2 or 3) to prevent massive outputs.";
            #     command = "tree -L {{depth}} --noreport -I 'node_modules|.git|dist|target'";
            #     schema = {
            #       properties = {
            #         depth = {
            #           type = "integer";
            #           description = "Depth of directory tree to display (e.g., 2)";
            #         };
            #       };
            #       required = [ "depth" ];
            #     };
            #   };
            #   "git-history" = {
            #     description = "Fetch the recent commit history of the repository to understand recent changes. Use this before modifying core files to see why they were changed.";
            #     command = "git log -n {{limit}} --pretty=format:'%h - %an: %s (%cr)'";
            #     schema = {
            #       properties = {
            #         limit = {
            #           type = "integer";
            #           description = "Number of commits to fetch (default: 5, max: 20)";
            #         };
            #       };
            #       required = [ "limit" ];
            #     };
            #   };
            #   "query-json" = {
            #     description = "Extract specific keys from massive JSON files without reading the entire file. Use standard jq filter syntax.";
            #     command = "jq -r '{{query}}' {{file_path}}";
            #     schema = {
            #       properties = {
            #         file_path = {
            #           type = "string";
            #           description = "Path to the JSON file";
            #         };
            #         query = {
            #           type = "string";
            #           description = "The jq query string (e.g., '.dependencies')";
            #         };
            #       };
            #       required = [
            #         "file_path"
            #         "query"
            #       ];
            #     };
            #   };
            # };
            mcpServers = {
              exa = {
                url = "https://mcp.exa.ai/mcp?exaApiKey=${config.sops.placeholder.exa}&tools=web_search_exa,web_search_advanced_exa,web_fetch_exa";
              };
            };
            providers = {
              litellm = {
                api = "openai-chat";
                url = "https://litellm.palebluebytes.space/v1";
                key = config.sops.placeholder.litellm_key;
                models = litellmModels;
              };
            };
            defaultAgent = "Architect";
            agent = {
              Architect = {
                "inherit" = "plan";
                mode = "primary";
                description = "Lead architect for project planning and structural design.";
                model = "${m."minimax"}";
                prompts = {
                  chat = "You are a Systems Architect. Analyze the context and user request. Output a step-by-step markdown plan detailing which files to modify and the logic required. Do not write the final implementation code.";
                };
              };
              Coder = {
                mode = "primary";
                description = "Senior developer focused on high-quality code implementation.";
                model = "${m."qwen3-coder"}";
                prompts = {
                  chat = "You are a Senior Developer. Implement the specific code changes requested based on the provided plan and file context. Output precise, clean code.";
                };
              };
              Fixer = {
                "inherit" = "code";
                mode = "subagent";
                description = "Debugging assistant that fixes errors in code and logs.";
                model = "${m."deepseek-flash"}";
                maxSteps = 15;
                systemPrompt = "You are a debugging assistant. Review the provided error logs and code. Output ONLY the corrected lines of code required to fix the error.";
              };
              "Database Administrator" = {
                mode = "subagent";
                description = "Expert in SQL migrations, schema analysis, and query optimization.";
                model = "${m."deepseek-pro"}";
                maxSteps = 10;
                systemPrompt = "You are an expert Database Administrator. Analyze schemas and write highly optimized, index-aware SQL migrations and queries. Output only valid SQL or execution plan explanations.";
              };
              Documenter = {
                mode = "subagent";
                description = "Technical writer that generates documentation and docstrings.";
                model = "${m."deepseek-pro"}";
                maxSteps = 10;
                systemPrompt = "You are a Senior Technical Writer. Review the provided code and generate comprehensive documentation, including inline docstrings and Markdown.";
              };
            };
            defaultModel = "litellm/deepseek-pro";
          };

        path = "${config.home.homeDirectory}/.config/eca/config.json";
      };
    };
  };
}
