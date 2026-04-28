{
  lib,
  rustPlatform,
}:

rustPlatform.buildRustPackage {
  pname = "annas-opds";
  version = "0.1.0";

  src = lib.cleanSource ./.;

  cargoLock = {
    lockFile = ./Cargo.lock;
  };

  meta = {
    description = "OPDS 2.0 JSON proxy for Anna's Archive search/download with EPUB scrubbing and optional Stump scan";
    homepage = "https://github.com/inkpot-monkey/nixos";
    license = with lib.licenses; [
      mit
      asl20
    ];
    maintainers = [ ];
    mainProgram = "annas-opds";
    platforms = lib.platforms.linux;
  };
}
