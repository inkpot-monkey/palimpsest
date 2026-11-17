# patchright — the undetected fork of playwright-python, packaged FROM THE PyPI WHEEL.
#
# WHY THIS FILE EXISTS AT ALL. nixpkgs has a `python3Packages.patchright`, and it is
# `broken = true` on purpose: it builds from the GitHub repo, and upstream's own
# pyproject there says "Only for test Runs, does not relate to actual Patchright
# package". The real artefact is assembled by upstream's `patchright_release.yml`
# workflow, which vendors a patched `patchright-core` npm package (the Node driver that
# does the actual CDP-level stealth patching) into the Python tree. Nothing in the git
# tree reproduces that, so the only honest source is the published wheel — which is why
# nixpkgs marks its own attempt broken rather than shipping it.
#
# ⚠ SO THIS DOES NOT OVERRIDE `python3Packages.patchright`. It is a separate attribute
# consumed explicitly by pkgs/scrapling. Putting it into `python3Packages` would rebuild
# the whole Python set for every host, to serve one consumer on one host.
#
# NEEDED BECAUSE SCRAPLING IMPORTS IT UNCONDITIONALLY — `engines/toolbelt/convertor.py`
# does a bare `from patchright.sync_api import …` at module load, so even the plain HTTP
# fetcher cannot be imported without it. (A patch making that import optional was written
# while this was being packaged and then dropped: shipping the real dependency is
# strictly better than shipping stubs that fail at first browser call.)
{
  lib,
  stdenv,
  python3,
  fetchurl,
  nodejs,
}:

let
  version = "1.64.4";

  # Per-platform wheels: the wheel carries a bundled Node binary for its own
  # architecture, so there is no `py3-none-any` to take instead. Hashes are PyPI's own
  # sha256 digests, converted to SRI.
  wheels = {
    x86_64-linux = {
      name = "patchright-${version}-py3-none-manylinux1_x86_64.whl";
      url = "https://files.pythonhosted.org/packages/3f/66/7b5e5a2098dca0f10cfd5313c7bc6ecd95890661cdd1bd033a5186b2d42f/patchright-${version}-py3-none-manylinux1_x86_64.whl";
      hash = "sha256-pYCu4W6J7yVSxn6POIu68bfTG0tRIRodS1hDArn+tp8=";
    };
    aarch64-linux = {
      name = "patchright-${version}-py3-none-manylinux_2_17_aarch64.manylinux2014_aarch64.whl";
      url = "https://files.pythonhosted.org/packages/31/3b/2f5a7fea04047389c063f1a2b2a77db0d53acd2cf1d339d7b74dd4718f4f/patchright-${version}-py3-none-manylinux_2_17_aarch64.manylinux2014_aarch64.whl";
      hash = "sha256-k9cZ3WopIbVTclYR1W1TruhffEbU1u/yILcbgXX/lTQ=";
    };
  };

  system = stdenv.hostPlatform.system;
in
python3.pkgs.buildPythonPackage {
  pname = "patchright";
  inherit version;

  format = "wheel";

  src = fetchurl (
    wheels.${system}
      or (throw "patchright: no wheel pinned for ${system} (add it from https://pypi.org/project/patchright/#files)")
  );

  dependencies = with python3.pkgs; [
    pyee
    greenlet
  ];

  # ── THE BUNDLED NODE CANNOT RUN HERE, AND THE FALLBACK IS A PYTHON DEFAULT ──────────
  # `_impl/_driver.py` resolves the driver interpreter as
  # `os.getenv("PLAYWRIGHT_NODEJS_PATH", str(driver_path / "node"))`, and that bundled
  # `node` is a plain manylinux ELF — it looks for /lib/ld-linux-*.so.1 and dies on
  # NixOS. Substituting the DEFAULT rather than exporting the variable from a wrapper is
  # what makes `python3 -c 'import patchright'` work as well as the console script: an
  # env var set by a wrapper reaches only things launched through that wrapper, and the
  # library is imported far more often than the CLI is run.
  #
  # The bundled binary is then deleted, so nothing can silently fall back to it and so
  # the closure does not carry a 100 MB executable it can never use. The win32 branch of
  # the same expression is left alone — it is unreachable on linux.
  postInstall = ''
    site=$out/${python3.sitePackages}
    substituteInPlace $site/patchright/_impl/_driver.py \
      --replace-fail 'str(driver_path / "node")' '"${lib.getExe nodejs}"'
    rm -f $site/patchright/driver/node
  '';

  # A wheel install has nothing to test, and upstream ships no tests in it either.
  doCheck = false;

  # Deliberately empty: importing patchright writes to the filesystem (it is the reason
  # nixpkgs' own derivation disables this too), so the check fails in the sandbox for a
  # reason that says nothing about whether the package works.
  pythonImportsCheck = [ ];

  meta = {
    description = "Undetected Python version of the Playwright testing and automation library";
    homepage = "https://github.com/Kaliiiiiiiiii-Vinyzu/patchright-python";
    changelog = "https://pypi.org/project/patchright/#history";
    license = lib.licenses.asl20;
    platforms = lib.attrNames wheels;
    sourceProvenance = [ lib.sourceTypes.binaryNativeCode ];
  };
}
