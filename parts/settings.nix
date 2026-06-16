{ inputs, self, ... }:
let
  # Load node metadata from secrets if available, otherwise use placeholders
  # This keeps the repository public-ready while remaining functional for the user.
  secretsNodes =
    if builtins.pathExists (self.lib.getSecretPath "nodes.nix") then
      import (self.lib.getSecretPath "nodes.nix")
    else
      { };

  # Helper to get metadata with a safe fallback
  getMeta =
    nodeName: path: default:
    let
      attrPath = [ nodeName ] ++ path;
    in
    if lib.attrByPath attrPath null secretsNodes != null then
      lib.attrByPath attrPath null secretsNodes
    else
      default;

  inherit (inputs.nixpkgs) lib;
  primaryDomain = "palebluebytes.space";

  services = {
    public = {
      matrix = {
        node = "kelpy";
        port = 6167;
        proxy = false;
      };
      mail = {
        node = "kelpy";
        port = 8082;
        proxy = false;
      };
      jellyfin = {
        node = "kelpy";
        port = 8096;
      };
    };
    private = {
      litellm = {
        node = "kelpy";
        port = 4000;
      };
      monitoring = {
        node = "kelpy";
        port = 3001;
      };
      paperless = {
        node = "kelpy";
        port = 28981;
      };
      torrent = {
        node = "kelpy";
        port = 8080;
      };
      affine = {
        node = "kelpy";
        port = 3010;
      };
      openclaw = {
        node = "kelpy";
        port = 8001;
      };
      aionui = {
        node = "kelpy";
        port = 25808;
      };
      # Home Assistant. It RUNS on rk1b, but is fronted by kelpy's Caddy (TLS via
      # Cloudflare DNS-01 + the internal_only tailnet guard), so `node` is the front
      # host (kelpy: where DNS points and Caddy runs) and `backendHost` is where Caddy
      # reverse-proxies to over tailscale. Reachable tailnet-only at home.<domain>.
      home = {
        node = "kelpy";
        port = 8123;
        backendHost = "rk1b";
      };
      # Local llama.cpp endpoint on Turing Pi RK1 node rk1a. (rk1b was repurposed as the
      # Home Assistant voice node and no longer serves an LLM, so there is no localLlmB.)
      localLlmA = {
        node = "rk1a";
        port = 8080;
      };
    };
  };

  allServiceEndpoints =
    (lib.mapAttrsToList (_: svc: "${svc.node}:${toString svc.port}") services.public)
    ++ (lib.mapAttrsToList (_: svc: "${svc.node}:${toString svc.port}") services.private);

  uniqueEndpoints = lib.unique allServiceEndpoints;

  checkPorts =
    if builtins.length uniqueEndpoints != builtins.length allServiceEndpoints then
      builtins.throw "Duplicate ports found on the same node in settings.nix! Endpoints: ${builtins.toJSON allServiceEndpoints}"
    else
      services;
in
{
  flake.settings = {
    admin.email = "admin@${primaryDomain}";
    inherit primaryDomain;
    mailDomain = primaryDomain;

    nodes.kelpy = {
      hostName = "kelpy";
      domain = "palebluebytes.space";
      tailscale = {
        ip4 = getMeta "kelpy" [ "tailscale" "ip4" ] "100.64.0.1";
        ip6 = getMeta "kelpy" [ "tailscale" "ip6" ] "fd7a:115c:a1e0::1";
      };
      public = {
        ip4 = getMeta "kelpy" [ "public" "ip4" ] "0.0.0.0";
        ip6 = getMeta "kelpy" [ "public" "ip6" ] "::1";
      };
    };

    nodes.porcupineFish = {
      hostName = "porcupineFish";
      tailscale = {
        ip4 = getMeta "porcupineFish" [ "tailscale" "ip4" ] "100.64.0.2";
        ip6 = getMeta "porcupineFish" [ "tailscale" "ip6" ] "fd7a:115c:a1e0::2";
      };
    };

    nodes.stargazer = {
      hostName = "stargazer";
      tailscale = {
        ip4 = getMeta "stargazer" [ "tailscale" "ip4" ] "100.64.0.3";
        ip6 = getMeta "stargazer" [ "tailscale" "ip6" ] "fd7a:115c:a1e0::3";
      };
    };

    nodes.sawtoothShark = {
      hostName = "sawtoothShark";
    };

    nodes.potbelliedSeahorse = {
      hostName = "potbelliedSeahorse";
    };

    nodes.rk1a = {
      hostName = "rk1a";
      tailscale = {
        ip4 = getMeta "rk1a" [ "tailscale" "ip4" ] "100.64.0.4";
        ip6 = getMeta "rk1a" [ "tailscale" "ip6" ] "fd7a:115c:a1e0::4";
      };
    };

    nodes.rk1b = {
      hostName = "rk1b";
      tailscale = {
        ip4 = getMeta "rk1b" [ "tailscale" "ip4" ] "100.64.0.5";
        ip6 = getMeta "rk1b" [ "tailscale" "ip6" ] "fd7a:115c:a1e0::5";
      };
    };

    services = checkPorts;
  };
}
