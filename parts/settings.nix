_: {
  flake.settings = {
    admin.email = "<SCRUBBED_EMAIL>";

    nodes.kelpy = {
      hostName = "kelpy";
      domain = "palebluebytes.space";
      tailscale = {
        ip4 = "100.64.10.90";
        ip6 = "fd7a:115c:a1e0::a13b:a5a";
      };
      public = {
        ip4 = "37.205.14.206";
        ip6 = "2a03:3b40:fe:896::1";
      };
    };

    nodes.porcupineFish = {
      hostName = "porcupineFish";
      tailscale = {
        ip4 = "100.107.42.51";
        ip6 = "fd7a:115c:a1e0::343b:2a33";
      };
    };

    nodes.stargazer = {
      hostName = "stargazer";
      tailscale = {
        ip4 = "100.95.39.9";
        ip6 = "fd7a:115c:a1e0::13b:2709";
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
