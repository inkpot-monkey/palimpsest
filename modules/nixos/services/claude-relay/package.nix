{
  lib,
  rustPlatform,
  pkg-config,
  cmake,
  perl,
  nasm,
}:

rustPlatform.buildRustPackage {
  pname = "claude-relay";
  version = "0.1.0";

  # Only the crate sources — never target/ or the sibling *.nix module files.
  src = lib.fileset.toSource {
    root = ./.;
    fileset = lib.fileset.unions [
      ./Cargo.toml
      ./Cargo.lock
      ./src
    ];
  };

  cargoLock.lockFile = ./Cargo.lock;

  # ring / aws-lc-sys (pulled transitively by reqwest's rustls stack) need these.
  nativeBuildInputs = [
    pkg-config
    cmake
    perl
    nasm
  ];

  # No tests in the crate yet; the behaviour is proven by the VM check.
  doCheck = false;

  meta = {
    description = "Relay persistent claude CLI sessions to/from Matrix (ADR-0025)";
    mainProgram = "claude-relay";
  };
}
