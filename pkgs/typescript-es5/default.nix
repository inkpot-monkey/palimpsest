# TypeScript 5, pinned, for one consumer: the `dns` app (parts/apps/dns).
#
# ── Why a pin exists at all ───────────────────────────────────────────────────────────────
# `pkgs.typescript` is now 7.x, which REMOVED the ES5 target along with every module kind
# `--outFile` accepted (None/AMD/System/UMD). That broke `nix run .#dns`, and it cannot be
# fixed by relaxing the target, because ES5 is a hard requirement on the far side rather
# than a preference:
#
#   dnscontrol 5.2.0 embeds `otto`, a strictly ES5.1 interpreter. Measured against the real
#   binary, it rejects `const` ("Unexpected reserved word"), `let`, arrow functions
#   ("Unexpected token >") and template literals ("Unexpected token ILLEGAL").
#
# And there is no other downleveller to reach for: esbuild refuses outright
# ("Transforming const to the configured target environment (es5) is not supported yet"),
# and swc does not currently build in nixpkgs. Nor is there anything to wait for upstream:
# dnscontrol v5.2.0 is the NEWEST release and its go.mod still pins
# github.com/robertkrimen/otto v0.5.1 (plus xddxdd/ottoext, which supplies the `require`
# that dnsconfig.ts uses for its data file).
#
# ── REMOVAL CONDITION ─────────────────────────────────────────────────────────────────────
# Delete this package and point parts/apps/dns back at `pkgs.typescript` the day dnscontrol
# ships a modern JS engine (goja would do — it has const/let/arrows/template literals). The
# swap is tractable but is deliberately NOT this pin's problem: pkg/js/js.go is ~10.5 KB
# with 11 otto call sites and the 67 KB helpers.js prelude is ES5 and would run unchanged,
# so it is a plausible upstream contribution — just not one worth carrying as a private
# fork of the tool that pushes live DNS.
#
# ── Why it is built this way ──────────────────────────────────────────────────────────────
# TypeScript is published as plain JavaScript, so there is nothing to compile: the npm
# tarball's lib/tsc.js is the compiler, and it only needs a node to run it. That makes this
# a fetch-and-wrap rather than a buildNpmPackage — no lockfile, no node_modules, no npm at
# build time. `typescript-es5` rather than `typescript-5` as a name, because what the
# consumer needs is the CAPABILITY (emit ES5), and that is what has to survive being read
# in three years, not the version number.
{
  lib,
  stdenvNoCC,
  fetchurl,
  nodejs,
  makeWrapper,
}:

stdenvNoCC.mkDerivation rec {
  pname = "typescript-es5";
  # The last TypeScript line that can still emit ES5. Do not bump this to 6 or 7 — that is
  # precisely what it exists to avoid.
  version = "5.9.3";

  src = fetchurl {
    url = "https://registry.npmjs.org/typescript/-/typescript-${version}.tgz";
    hash = "sha256-EOEIyc99Xyh5BT3/GFFftAWr8szvY+qvAX2cVxaHodM=";
  };

  nativeBuildInputs = [ makeWrapper ];

  # The tarball unpacks to `package/`; stdenv's default unpackPhase handles it and drops us
  # inside, so there is no sourceRoot to set.

  dontBuild = true;

  installPhase = ''
    runHook preInstall

    mkdir -p "$out/lib/typescript"
    cp -r lib package.json "$out/lib/typescript/"

    # tsc and tsserver are the only two entry points anything here uses. Wrapped against a
    # pinned node rather than shipping the tarball's own bin/ shims, which resolve `node`
    # off PATH and would silently pick up whatever the caller happened to have.
    makeWrapper ${lib.getExe nodejs} "$out/bin/tsc" \
      --add-flags "$out/lib/typescript/lib/tsc.js"
    makeWrapper ${lib.getExe nodejs} "$out/bin/tsserver" \
      --add-flags "$out/lib/typescript/lib/tsserver.js"

    runHook postInstall
  '';

  meta = {
    description = "TypeScript ${version} — pinned for ES5 emit, which TypeScript 7 removed";
    homepage = "https://www.typescriptlang.org/";
    license = lib.licenses.asl20;
    mainProgram = "tsc";
    platforms = lib.platforms.all;
  };
}
