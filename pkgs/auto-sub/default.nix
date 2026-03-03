{
  writeShellApplication,
  ffmpeg,
  jq,
  system ? builtins.currentSystem,
}:

let
  # Pinned to Nixpkgs commit 5720aa5c2cf5df0bd548e8522c543e321df917b5 (Hydra Build 322063957)
  pinnedPkgs =
    import
      (builtins.fetchTarball {
        url = "https://github.com/NixOS/nixpkgs/archive/5720aa5c2cf5df0bd548e8522c543e321df917b5.tar.gz";
        sha256 = "sha256:1c4jv3p4fkraag15y39rd38n15xrdknx6r6vnnp7j66a307g84pp";
      })
      {
        inherit system;
        config.allowUnfree = true;
      };
in
writeShellApplication {
  name = "auto-sub";

  runtimeInputs = [
    ffmpeg
    jq
    pinnedPkgs.whisperx
  ];

  text = builtins.readFile ./auto-sub.sh;
}
