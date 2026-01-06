{
  lib,
  buildNpmPackage,
  fetchFromGitHub,
  python3,
  pkg-config,
  buildGoModule,
  esbuild,
}:

let
  esbuild' = esbuild.override {
    buildGoModule =
      args:
      buildGoModule (
        args
        // (
          let
            version = "0.25.10";
          in
          {
            inherit version;
            src = fetchFromGitHub {
              owner = "evanw";
              repo = "esbuild";
              tag = "v${version}";
              hash = "sha256-EkQOIHqVrULig7s3w4nI8/yVIz2NZA5DCrMof0HHvHM=";
            };
            vendorHash = "sha256-+BfxCyg0KkDQpHt/wycy/8CTG6YBA/VJvJFhhzUnSiQ=";
          }
        )
      );
  };
in
buildNpmPackage (finalAttrs: {
  pname = "n8n-mcp";
  version = "2.23.0";

  src = fetchFromGitHub {
    owner = "czlonkowski";
    repo = "n8n-mcp";
    rev = "v${finalAttrs.version}";
    hash = "sha256-0kYAfehg2HGC4bPf18x+Dh4M8499y9vLcalqOMzhNj8=";
  };

  npmDepsHash = "sha256-qrZOshZP/pZTg3nIjQHfa519z+XeHV2HoCcdD0EowVQ=";

  makeCacheWritable = true;
  npmFlags = [ "--legacy-peer-deps" ];

  nativeBuildInputs = [
    (python3.withPackages (ps: [ ps.setuptools ]))
    pkg-config
  ];

  ESBUILD_BINARY_PATH = lib.getExe esbuild';

  meta = {
    description = "Model Context Protocol server for n8n";
    homepage = "https://github.com/czlonkowski/n8n-mcp";
    license = lib.licenses.mit;
    mainProgram = "n8n-mcp";
    maintainers = [ ];
  };
})
