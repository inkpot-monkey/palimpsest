{
  config,
  self,
  ...
}:

let
  inherit (self.nixosConfigurations.kelpy.config.services) litellm;

  # Read prompt files relative to this file's location
  promptsDir = ./prompts;
  readPrompt = name: builtins.readFile (promptsDir + "/${name}.md");

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
          chat = readPrompt "architect";
        };
      };

      Coder = {
        mode = "primary";
        description = "Senior developer focused on high-quality code implementation.";
        model = "${m."qwen3-coder"}";
        prompts = {
          chat = readPrompt "coder";
        };
      };

      explorer = {
        "inherit" = "code";
        mode = "subagent";
        description = "Codebase search specialist. Focuses on finding and reading file contents without modifying the system.";
        model = "${m."deepseek-flash"}";
        maxSteps = 10;
        systemPrompt = readPrompt "explorer";
      };

      general = {
        "inherit" = "code";
        mode = "subagent";
        description = "General-purpose agent for researching complex questions and executing multi-step tasks.";
        model = "${m."deepseek-flash"}";
        maxSteps = 15;
        systemPrompt = readPrompt "general";
      };

      Fixer = {
        "inherit" = "code";
        mode = "subagent";
        description = "Debugging assistant that fixes errors in code and logs.";
        model = "${m."deepseek-flash"}";
        maxSteps = 15;
        systemPrompt = readPrompt "fixer";
      };

      "Database Administrator" = {
        mode = "subagent";
        description = "Expert in SQL migrations, schema analysis, and query optimization.";
        model = "${m."deepseek-pro"}";
        maxSteps = 10;
        systemPrompt = readPrompt "dba";
      };

      Documenter = {
        mode = "subagent";
        description = "Technical writer that generates documentation and docstrings.";
        model = "${m."deepseek-pro"}";
        maxSteps = 10;
        systemPrompt = readPrompt "documenter";
      };

      Committer = {
        "inherit" = "code";
        mode = "subagent";
        description = "Git commit specialist that creates discrete conventional commits from changed files.";
        model = "${m."deepseek-flash"}";
        maxSteps = 10;
        systemPrompt = readPrompt "committer";
      };
    };

    defaultModel = "litellm/deepseek-pro";
  };

  configString = builtins.toJSON jsonConfig;
}
