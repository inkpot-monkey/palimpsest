_: final: prev: {
  flexget = prev.flexget.overrideAttrs (oldAttrs: {
    nativeBuildInputs = (oldAttrs.nativeBuildInputs or [ ]) ++ [ final.unzip ];

    # Extract assets into the flexget/ui/v2/dist directory
    postInstall = (oldAttrs.postInstall or "") + ''
      UI_V2_PATH=$out/lib/python3.13/site-packages/flexget/ui/v2
      # dist.zip contains a 'dist' folder, unzip it into ui/v2 to get ui/v2/dist
      unzip -o ${
        final.fetchurl {
          url = "https://github.com/Flexget/webui/releases/download/2.0.29/dist.zip";
          sha256 = "0r0rbdk4wm9ypmkrrngdkislb205c4wfbqh1si5bbk5hz055pip6";
        }
      } -d $UI_V2_PATH
    '';
  });
}
