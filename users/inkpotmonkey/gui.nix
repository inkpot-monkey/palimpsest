{ pkgs, ... }:

let
  RStudio-with-my-packages = pkgs.rstudioWrapper.override {
    packages = with pkgs.rPackages; [
      ggplot2
      dplyr
      xts
    ];
  };

in
{
  imports = [
    ./ai.nix
    ./kanata.nix
  ];

  home.sessionVariables = {
    BROWSER = "vivaldi";
  };

  home.packages = with pkgs; [
    RStudio-with-my-packages

    vesktop

    postman

    gimp3

    popcorntime
    miraclecast

    calibre
    spotify
    yt-dlp
    youtube-tui
    subsurface
    ledger-live-desktop
    signal-desktop
    lens
    beeper

    anki-bin

    vscode-fhs
    distrobox
    quickemu

    zoom-us

    vivaldi
    brave
    nss_latest

    ffmpeg
    whisper-cpp
    deepfilternet

    zulip

    wl-clipboard

    blender

    # Need to start the pritunl-client-service manually
    pritunl-client

  ];

  programs.mpv = {
    enable = true;

    package = (
      pkgs.mpv-unwrapped.wrapper {
        scripts = with pkgs.mpvScripts; [ modernz ];

        mpv = pkgs.mpv-unwrapped.override {
          waylandSupport = true;
          ffmpeg = pkgs.ffmpeg-full;
        };
      }
    );

    config = {
      profile = "high-quality";
      ytdl-format = "bestvideo+bestaudio";
      cache-default = 4000000;
    };
  };
}
