{
  lib,
  rustPlatform,
  fetchFromGitHub,
  fetchzip,
  pkg-config,
  openssl,
  writeShellScriptBin,
}:
let
  version = "0.1.0";

  # Pre-built React SPA extracted from the official Linux release bundle.
  # The zip contains both the server binary (ignored) and the client/ web assets.
  webUiZip = fetchzip {
    url = "https://github.com/stumpapp/stump/releases/download/v${version}/linux-build-results.zip";
    hash = "sha256-rQD6AtgSVHd3sebAPbWBlzTjFGFDKGghWRzGu8xaYdA=";
    # fetchzip strips the top-level directory; the web assets are in client/
    stripRoot = false;
  };
in
rustPlatform.buildRustPackage {
  pname = "stump";
  inherit version;

  src = fetchFromGitHub {
    owner = "stumpapp";
    repo = "stump";
    rev = "v${version}";
    hash = "sha256-FavhqSckX/d3UAxLMUb3EwrNolUjZrkZNISP7GwMR58=";
  };

  cargoHash = "sha256-qcNA4u3sjHTJnvA3KUfjEuYxjhv6tGYg85dZiiDUJPc=";

  # Only build the server binary, not the desktop Tauri app
  buildAndTestSubdir = "apps/server";

  nativeBuildInputs = [
    pkg-config
    (writeShellScriptBin "git" ''
      echo "v${version}"
    '')
  ];
  buildInputs = [ openssl ];

  # Disable the default test run – the workspace tests require a running SQLite
  # database and various external crates that aren't easily sandboxed.
  doCheck = false;

  postInstall = ''
    # Install the pre-built web UI alongside the binary
    mkdir -p $out/share/stump
    cp -r ${webUiZip}/client $out/share/stump/web
  '';

  meta = {
    description = "A free and open source comics, manga and digital book server with OPDS support";
    homepage = "https://stumpapp.dev";
    changelog = "https://github.com/stumpapp/stump/releases/tag/v${version}";
    license = lib.licenses.mit;
    maintainers = [ ];
    platforms = lib.platforms.linux;
    mainProgram = "stump_server";
  };
}
