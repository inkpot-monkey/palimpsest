# MCP SDK 2.x, built locally because nixpkgs is behind (palimpsest#112).
#
# WHY THIS FILE EXISTS
# --------------------
# Upstream supernote migrated to `mcp>=2.0.0` (allenporter/supernote 095025c, 2026-08-02) and
# `supernote/server/app.py` imports `mcp.server.mcpserver` unconditionally at module scope. The
# fleet nixpkgs pin ships `python313Packages.mcp` 1.26.0, whose module layout has no
# `mcp.server.mcpserver` — so the packaged server fails at *import*, not at first MCP request.
# We cannot dodge it by not using MCP: the import is unconditional, even though this deployment
# deliberately firewalls the MCP port off (LLM features are v1-out — see
# modules/nixos/profiles/supernote.nix).
#
# Pinning upstream to a revision before that bump is not an option either: the device planner
# surface this whole package exists for (`/api/file/schedule/{group,task}/all`, `task/list`) landed
# in 3848bfb, five minutes AFTER the mcp bump — so "old enough for nixpkgs' mcp" and "new enough
# to have the device routes" do not overlap.
#
# So: build the 2.x chain here, in the same spirit as the `potracer` / `aiohttp-asgi` stubs in
# ./default.nix. `mcp` 2.x replaced httpx with the httpx2 rewrite, which drags in httpcore2:
#
#     mcp 2.0.0 ── mcp-types 2.0.0
#               └─ httpx2 2.10.0 ── httpcore2 2.10.0
#
# All four are published as pure-Python `py3-none-any` WHEELS, and that is what we install. Their
# sdists build with `uv-dynamic-versioning` / `hatch-fancy-pypi-readme`, neither of which is in the
# fleet nixpkgs pin — packaging two build backends to rebuild an already-universal wheel buys
# nothing here. Runtime deps still come from nixpkgs, so the closure is normal.
#
# DELETE THIS FILE when the fleet nixpkgs pin carries `python3Packages.mcp` >= 2.0.0: drop the
# import in ./default.nix and go back to the plain `python.pkgs.mcp`. Everything below is a
# stopgap, not a considered packaging of these projects.
{ python }:
let
  ps = python.pkgs;

  # A `py3-none-any` wheel straight off PyPI. `dist`/`python` are the wheel's own tags.
  wheel =
    {
      pname,
      version,
      hash,
      pypiName ? pname,
    }:
    ps.fetchPypi {
      pname = pypiName;
      inherit version hash;
      format = "wheel";
      dist = "py3";
      python = "py3";
    };

  httpcore2 = ps.buildPythonPackage rec {
    pname = "httpcore2";
    version = "2.10.0";
    format = "wheel";
    src = wheel {
      inherit pname version;
      hash = "sha256-ffBs+zQHDK5PfIm+adwQleyhOOlwTO/7mNJcGRKrbwE=";
    };
    dependencies = [
      ps.h11
      ps.truststore
      ps.anyio
      ps.certifi
    ];
    pythonImportsCheck = [ "httpcore2" ];
    # Wheel install: nothing to run, and the suite wants a live loopback HTTP server.
    doCheck = false;
  };

  httpx2 = ps.buildPythonPackage rec {
    pname = "httpx2";
    version = "2.10.0";
    format = "wheel";
    src = wheel {
      inherit pname version;
      hash = "sha256-XjGUpDJwHhzG9pqLGy+hme+QcBP+3o2aCaLFt7gUGhg=";
    };
    dependencies = [
      httpcore2
      ps.idna
      ps.anyio
      ps.truststore
      ps.certifi
    ];
    pythonImportsCheck = [ "httpx2" ];
    doCheck = false;
  };

  mcp-types = ps.buildPythonPackage rec {
    pname = "mcp-types";
    version = "2.0.0";
    format = "wheel";
    src = wheel {
      inherit pname version;
      pypiName = "mcp_types";
      hash = "sha256-ay3nl8onl/Vot5Up4bJZSONN5RG8wL2C/vEDmm0bjrA=";
    };
    dependencies = [
      ps.pydantic
      ps.typing-extensions
    ];
    pythonImportsCheck = [ "mcp_types" ];
    doCheck = false;
  };
in
ps.buildPythonPackage rec {
  pname = "mcp";
  version = "2.0.0";
  format = "wheel";
  src = wheel {
    inherit pname version;
    hash = "sha256-HLTHXS0se4wddWNV5dgqOfKCLMfxPiKiBR18o1kjSdY=";
  };
  dependencies = [
    httpx2
    mcp-types
    ps.anyio
    ps.jsonschema
    ps.opentelemetry-api
    ps.pydantic
    ps.pyjwt
    ps.python-multipart
    ps.sse-starlette
    ps.starlette
    ps.typing-extensions
    ps.typing-inspection
    ps.uvicorn
  ];
  # The submodule upstream's app.py imports; a layout regression fails here, by name.
  pythonImportsCheck = [
    "mcp"
    "mcp.server.mcpserver"
  ];
  doCheck = false;
}
