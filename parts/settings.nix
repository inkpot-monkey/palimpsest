_: {
  flake.settings = {
    admin.email = "thomas@palebluebytes.xyz";

    nodes.kelpy = {
      hostName = "kelpy";
      domain = "palebluebytes.space";
      tailscale = {
        ip4 = "100.108.126.7";
        ip6 = "fd7a:115c:a1e0::753b:7e07";
      };
      public = {
        ip4 = "37.205.14.206";
        ip6 = "2a03:3b40:fe:896::1";
      };
    };

    nodes.porcupineFish = {
      hostName = "porcupineFish";
      tailscale = {
        ip4 = "100.90.224.93";
        ip6 = "fd7a:115c:a1e0::ab3b:e05d";
      };
    };

    nodes.stargazer = {
      hostName = "stargazer";
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
