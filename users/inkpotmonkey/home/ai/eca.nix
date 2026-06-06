{
  config,
  self,
  pkgs,
  ...
}:

let
  inherit (self.nixosConfigurations.kelpy.config.services) litellm;

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

rec {
  jsonConfig = {
    # Skills loaded from external directory
    skills = [
      { path = "~/.agent/skills"; }
    ];

    mcpServers = {
      exa = {
        url = "https://mcp.exa.ai/mcp?exaApiKey=${config.sops.placeholder.exa}&tools=web_search_exa,web_search_advanced_exa,web_fetch_exa";
      };
      context-hub = {
        command = "chub-mcp";
      };
      # MCP-NixOS — search NixOS packages, options, Home Manager options,
      # nix-darwin, FlakeHub, Nix functions (noogle), and NixOS Wiki.
      # Prevents agents from hallucinating package names and config options.
      nixos = {
        command = "mcp-nixos";
      };
      # Emacs MCP — lets the agent see/interact with your running Emacs
      # buffers via emacsclient. Requires a running Emacs server
      # (services.emacs.socketActivation.enable = true).
      emacs = {
        command = "npx";
        args = [
          "-y"
          "@keegancsmith/emacs-mcp-server"
        ];
      };

      # Playwright MCP — browser automation
      playwright = {
        command = "npx";
        args = [
          "-y"
          "@playwright/mcp"
        ];
        env = {
          PLAYWRIGHT_BROWSERS_PATH = "${pkgs.playwright-driver.browsers}";
          PLAYWRIGHT_NODEJS_PATH = "${pkgs.nodejs}/bin/node";
          PLAYWRIGHT_SKIP_BROWSER_DOWNLOAD = "1";
          PLAYWRIGHT_SKIP_VALIDATE_HOST_REQUIREMENTS = "true";
        };
      };

      # GitHub MCP — interact with GitHub repositories
      github = {
        command = "npx";
        args = [
          "-y"
          "@modelcontextprotocol/server-github"
        ];
        env = {
          GITHUB_PERSONAL_ACCESS_TOKEN = config.sops.placeholder.github_token;
        };
      };

      # Memory MCP — persistent knowledge graph
      memory = {
        command = "npx";
        args = [
          "-y"
          "@modelcontextprotocol/server-memory"
        ];
      };

      # Sequential Thinking MCP — structured reasoning
      sequential-thinking = {
        command = "npx";
        args = [
          "-y"
          "@modelcontextprotocol/server-sequential-thinking"
        ];
      };
      # Rust MCP — runs cargo build, test, clippy, add deps, and more
      # directly from the agent. Installed as a Nix package.
      # rust = {
      #   command = "rust-mcp-server";
      # };
    };

    providers = {
      litellm = {
        api = "openai-chat";
        url = "https://litellm.palebluebytes.space/v1";
        key = config.sops.placeholder.litellm_key;
        models = litellmModels;
      };
    };

    # defaultAgent = "Architect";

    # agent = {
    #   Architect = {
    #     "inherit" = "plan";
    #     mode = "primary";
    #     description = "Lead architect for project planning and structural design.";
    #     model = "${m."deepseek-pro"}";
    #     prompts = {
    #       chat = readPrompt "architect";
    #     };
    #   };

    #   Coder = {
    #     mode = "primary";
    #     description = "Senior developer focused on high-quality code implementation.";
    #     model = "${m."qwen3-coder"}";
    #     prompts = {
    #       chat = readPrompt "coder";
    #     };
    #   };

    #   explorer = {
    #     "inherit" = "code";
    #     mode = "subagent";
    #     description = "Codebase search specialist. Focuses on finding and reading file contents without modifying the system.";
    #     model = "${m."deepseek-flash"}";
    #     maxSteps = 10;
    #     systemPrompt = readPrompt "explorer";
    #   };

    #   general = {
    #     "inherit" = "code";
    #     mode = "subagent";
    #     description = "General-purpose agent for researching complex questions and executing multi-step tasks.";
    #     model = "${m."deepseek-flash"}";
    #     maxSteps = 15;
    #     systemPrompt = readPrompt "general";
    #   };

    #   Fixer = {
    #     "inherit" = "code";
    #     mode = "subagent";
    #     description = "Debugging assistant that fixes errors in code and logs.";
    #     model = "${m."deepseek-flash"}";
    #     maxSteps = 15;
    #     systemPrompt = readPrompt "fixer";
    #   };

    #   "Database Administrator" = {
    #     mode = "subagent";
    #     description = "Expert in SQL migrations, schema analysis, and query optimization.";
    #     model = "${m."deepseek-pro"}";
    #     maxSteps = 10;
    #     systemPrompt = readPrompt "dba";
    #   };

    #   Documenter = {
    #     mode = "subagent";
    #     description = "Technical writer that generates documentation and docstrings.";
    #     model = "${m."deepseek-pro"}";
    #     maxSteps = 10;
    #     systemPrompt = readPrompt "documenter";
    #   };

    #   Committer = {
    #     "inherit" = "code";
    #     mode = "subagent";
    #     description = "Git commit specialist that creates discrete conventional commits from changed files.";
    #     model = "${m."deepseek-flash"}";
    #     maxSteps = 10;
    #     systemPrompt = readPrompt "committer";
    #   };
    # };

    defaultModel = "litellm/deepseek-flash";

    # customTools = {
    #   "code-search" = {
    #     description = "Search codebase content using ripgrep.";
    #     command = "rg --color=never --line-number --smart-case {{query}} {{directory}}";
    #     schema = {
    #       properties = {
    #         query = {
    #           type = "string";
    #           description = "Search pattern";
    #         };
    #         directory = {
    #           type = "string";
    #           description = "Directory to search within";
    #         };
    #         file_type = {
    #           type = "string";
    #           description = "File type filter (e.g., 'py', 'js', 'nix')";
    #         };
    #       };
    #       required = [ "query" ];
    #     };
    #   };
    #   "find-files" = {
    #     description = "Find files by name or extension across the project.";
    #     command = "fd --type f --hidden --exclude .git --exclude node_modules {{pattern}} {{directory}}";
    #     schema = {
    #       properties = {
    #         pattern = {
    #           type = "string";
    #           description = "File name pattern (e.g., '*.ts', 'config.json')";
    #         };
    #         directory = {
    #           type = "string";
    #           description = "Directory to search within";
    #         };
    #       };
    #       required = [ "pattern" ];
    #     };
    #   };
    #   "project-tree" = {
    #     description = "View the directory structure to understand project layout. Keep depth low (2-3).";
    #     command = "tree -L {{depth}} --noreport -I 'node_modules|.git|dist|target|result'";
    #     schema = {
    #       properties = {
    #         depth = {
    #           type = "integer";
    #           description = "Depth of directory tree";
    #         };
    #       };
    #       required = [ "depth" ];
    #     };
    #   };
    #   "git-history" = {
    #     description = "Fetch recent commit history.";
    #     command = "git log -n {{limit}} --pretty=format:'%h - %an: %s (%cr)'";
    #     schema = {
    #       properties = {
    #         limit = {
    #           type = "integer";
    #           description = "Number of commits (max 20)";
    #         };
    #       };
    #       required = [ "limit" ];
    #     };
    #   };
    #   "query-json" = {
    #     description = "Extract specific keys from large JSON files using jq.";
    #     command = "jq -r '{{query}}' {{file_path}}";
    #     schema = {
    #       properties = {
    #         file_path = {
    #           type = "string";
    #           description = "Path to JSON file";
    #         };
    #         query = {
    #           type = "string";
    #           description = "jq query (e.g., '.dependencies')";
    #         };
    #       };
    #       required = [
    #         "file_path"
    #         "query"
    #       ];
    #     };
    #   };
    # };
  };

  configString = builtins.toJSON jsonConfig;
}
