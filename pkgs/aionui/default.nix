{
  lib,
  stdenv,
  fetchurl,
  autoPatchelfHook,
  zlib,
  xz,
  openssl,
}:

# AionUi WebUI server — the headless "aionui-web" runtime (no Electron).
#
# Upstream is a large Electron/tsx monorepo (Node 22-24, electron-vite, native
# better-sqlite3). Rather than rebuild that from source, we consume the official
# per-release standalone tarball, which ships a Bun-compiled `aionui-web`
# launcher, a Bun-compiled `aioncore` backend, a bundled Node v24 runtime, and
# the ACP adapters (incl. a bundled Claude Agent SDK). All of these are
# dynamically linked against /lib64/ld-linux, so autoPatchelfHook rewrites them
# for the Nix store. (Same prebuilt-release approach as ./stump.)
stdenv.mkDerivation rec {
  pname = "aionui-web";
  version = "2.1.14";

  src = fetchurl {
    url = "https://github.com/iOfficeAI/AionUi/releases/download/v${version}/aionui-web-${version}-linux-x86_64.tar.gz";
    hash = "sha256-LaPh/75xD0X2bEoOrSTycVcmqy5IDQqTrW4H17XDX4M=";
  };

  sourceRoot = "aionui-web";

  nativeBuildInputs = [ autoPatchelfHook ];

  # libc/pthread/dl/m come from glibc (autoPatchelf pulls it in automatically);
  # the bundled Node v24 also needs libstdc++/libgcc_s (stdenv.cc.cc.lib) and zlib.
  buildInputs = [
    stdenv.cc.cc.lib
    zlib
    xz # liblzma.so.5 (aioncore backend)
    openssl # libssl/libcrypto.so.3 (codex-acp adapter)
  ];

  # Bun single-file executables append a payload after the ELF and locate it via
  # /proc/self/exe — stripping risks corrupting that trailer, so leave them be.
  dontStrip = true;
  dontConfigure = true;
  dontBuild = true;

  installPhase = ''
    runHook preInstall

    mkdir -p "$out/libexec/aionui-web" "$out/bin"
    cp -r . "$out/libexec/aionui-web/"

    # We build against glibc; drop the musl variants of the bundled claude binary
    # so autoPatchelfHook doesn't trip over musl-linked ELFs (and to save closure).
    find "$out/libexec/aionui-web" -type d -name '*-musl*' -prune -exec rm -rf {} +

    # The launcher resolves its bundled adapters/static assets relative to its own
    # path (/proc/self/exe), so a symlink (not a wrapper) preserves that layout.
    ln -s "$out/libexec/aionui-web/aionui-web" "$out/bin/aionui-web"

    runHook postInstall
  '';

  meta = {
    description = "AionUi WebUI server — browser frontend that drives Claude Code and other agents via ACP";
    homepage = "https://github.com/iOfficeAI/AionUi";
    license = lib.licenses.asl20;
    platforms = [ "x86_64-linux" ];
    sourceProvenance = [ lib.sourceTypes.binaryNativeCode ];
    mainProgram = "aionui-web";
  };
}
