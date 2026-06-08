{
  lib,
  rustPlatform,
  fetchFromGitHub,
  writeShellScriptBin,
}:

rustPlatform.buildRustPackage rec {
  pname = "rust-mcp-server";
  version = "0.3.6";

  src = fetchFromGitHub {
    owner = "Vaiz";
    repo = "rust-mcp-server";
    rev = "v${version}";
    hash = "sha256-WFaQwEkhiBQUw+yVdLnxF8lyM/ewL1twbofVvCMLdWk";
  };

  cargoLock = {
    lockFile = ./Cargo.lock;
  };

  nativeBuildInputs = [
    # Provide a fake git for build.rs, which runs `git rev-parse --short HEAD`
    # to embed the commit hash into the binary.
    (writeShellScriptBin "git" ''
      echo "v${version}"
    '')
  ];

  # Tests require network access and a cargo project
  doCheck = false;

  meta = {
    description = "MCP server for Rust development — run cargo build, test, clippy, add deps, and more via LLM agents";
    homepage = "https://github.com/Vaiz/rust-mcp-server";
    changelog = "https://github.com/Vaiz/rust-mcp-server/releases/tag/v${version}";
    license = lib.licenses.unlicense;
    maintainers = [ ];
    platforms = lib.platforms.linux;
    mainProgram = "rust-mcp-server";
  };
}
