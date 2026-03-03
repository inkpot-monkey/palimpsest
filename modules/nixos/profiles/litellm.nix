{
  config,
  settings,
  ...
}:

{
  sops.templates."litellm-env".content = ''
    DEEPINFRA_API_KEY=${config.sops.placeholder."apikey@api.deepinfra.com"}
    GEMINI_API_KEY=${config.sops.placeholder."apikey@generativelanguage.googleapis.com"}
    ANTHROPIC_API_KEY=${config.sops.placeholder."apikey@api.anthropic.com"}
    LITELLM_MASTER_KEY=${config.sops.placeholder.litellm_key}
  '';

  sops.secrets = {
    "apikey@api.deepinfra.com" = { };
    "apikey@generativelanguage.googleapis.com" = { };
    "apikey@api.anthropic.com" = { };
    litellm_key = {
      key = "litellm-key";
    };
  };

  services.litellm = {
    enable = true;
    environmentFile = config.sops.templates."litellm-env".path;
    host = "127.0.0.1";
    inherit (settings.services.private.litellm) port;

    settings = {
      master_key = "os.environ/LITELLM_MASTER_KEY";
      model_list = [

        {
          model_name = "deepinfra/meta-llama/Llama-3-70b-instruct";
          litellm_params = {
            model = "deepinfra/meta-llama/Meta-Llama-3-70B-Instruct";
            api_key = "os.environ/DEEPINFRA_API_KEY";
          };
        }
        {
          model_name = "whisper";
          litellm_params = {
            model = "deepinfra/openai/whisper-large-v3";
            api_key = "os.environ/DEEPINFRA_API_KEY";
          };
          model_info = {
            mode = "audio_transcription";
          };
        }
        {
          model_name = "gemini/gemini-1.5-pro";
          litellm_params = {
            model = "gemini/gemini-1.5-pro";
            api_key = "os.environ/GEMINI_API_KEY";
          };
        }
        {
          model_name = "anthropic/claude-3-5-sonnet-20240620";
          litellm_params = {
            model = "anthropic/claude-3-5-sonnet-20240620";
            api_key = "os.environ/ANTHROPIC_API_KEY";
          };
        }
        {
          model_name = "deepinfra/deepseek-ai/DeepSeek-V3";
          litellm_params = {
            model = "deepinfra/deepseek-ai/DeepSeek-V3.2";
            api_key = "os.environ/DEEPINFRA_API_KEY";
          };
        }
      ];
    };
  };
}
