{ inputs, self, ... }:
let
  # Load node metadata from secrets if available, otherwise use placeholders
  # This keeps the repository public-ready while remaining functional for the user.
  secretsNodes =
    if builtins.pathExists (self.lib.getSecretPath "nodes.nix") then import (self.lib.getSecretPath "nodes.nix") else { };

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

    services = {
      public = {
        matrix = {
          node = "kelpy";
          port = 6167;
          proxy = false;
        };
        mail = {
          node = "kelpy";
          port = 8080;
          proxy = false;
        };
        jellyfin = {
          node = "kelpy";
          port = 8096;
        };
        flexget = {
          node = "kelpy";
          port = 5050;
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
          port = 9091;
        };
        affine = {
          node = "kelpy";
          port = 3010;
        };
      };
    };
  };
}
