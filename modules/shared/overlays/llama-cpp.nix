_: final: prev: {
  # Rebuild llama-cpp with libcurl so `llama-server -hf`/`-hfd` can pull GGUFs
  # from HuggingFace at runtime (the nixpkgs build omits curl entirely).
  llama-cpp = prev.llama-cpp.overrideAttrs (oldAttrs: {
    buildInputs = (oldAttrs.buildInputs or [ ]) ++ [ final.curl ];
    cmakeFlags = (oldAttrs.cmakeFlags or [ ]) ++ [
      (final.lib.cmakeBool "LLAMA_CURL" true)
    ];
  });
}
