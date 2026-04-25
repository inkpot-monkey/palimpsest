{
  config,
  lib,
  pkgs,
  inputs,
  ...
}:

let
  cfg = config.custom.profiles.affine;
  domain = "affine.${config.networking.domain}";
in
{
  options.custom.profiles.affine = {
    enable = lib.mkEnableOption "Affine self-hosted workspace configuration";
    port = lib.mkOption {
      type = lib.types.port;
      default = 3010;
      description = "The port Affine will listen on localhost.";
    };
    internalIp = lib.mkOption {
      type = lib.types.str;
      default = "10.88.0.1";
      description = "The internal IP of the container host, used for containers to reach host services.";
    };
  };

  config = lib.mkIf cfg.enable {
    # --- Secrets & Templates ---
    sops.secrets.affine_password = {
      sopsFile = ../../../../secrets + "/profiles/affine.yaml";
      owner = "postgres";
    };

    sops.templates."affine-env" = {
      content = ''
        DATABASE_URL=postgresql://affine:${config.sops.placeholder.affine_password}@${cfg.internalIp}:5432/affine
      '';
    };

    # --- Database (PostgreSQL) ---
    services.postgresql = {
      enable = true;
      package = pkgs.postgresql_16;
      extensions = ps: [ ps.pgvector ];
      enableTCPIP = true; # CRITICAL: Allow TCP connections

      settings = {
        # Bind to all addresses but restrict via firewall.
        listen_addresses = lib.mkForce "*";
      };

      ensureDatabases = [ "affine" ];
      ensureUsers = [
        {
          name = "affine";
          ensureDBOwnership = true;
        }
      ];

      authentication = lib.mkForce ''
        # TYPE  DATABASE    USER        ADDRESS            METHOD
        local   all         all                            trust
        host    affine      affine      10.88.0.0/16       scram-sha-256
        host    affine      affine      127.0.0.1/32       scram-sha-256
      '';
    };

    systemd.services.postgresql.postStart = lib.mkAfter ''
      TEMP_SQL=$(mktemp)
      trap "rm -f $TEMP_SQL" EXIT
      chmod 600 $TEMP_SQL

      # Just update the password, the role already exists!
      echo "ALTER ROLE affine WITH PASSWORD '$(cat ${config.sops.secrets.affine_password.path})';" > $TEMP_SQL

      ${config.services.postgresql.package}/bin/psql -U postgres -d postgres -f $TEMP_SQL
    '';

    # --- Cache (Redis) ---
    services.redis.servers.affine = {
      enable = true;
      port = 6379;
      bind = "0.0.0.0"; # Listen on all interfaces, restricted by firewall
    };

    # --- Affine Container ---
    systemd.tmpfiles.rules = [
      "d /var/lib/affine/storage 0755 root root -"
      "d /var/lib/affine/config 0755 root root -"
    ];

    virtualisation.oci-containers.containers.affine = {
      image = "ghcr.io/toeverything/affine:stable";
      # CRITICAL: Bind to 127.0.0.1 to prevent exposing the raw backend to the internet
      ports = [ "127.0.0.1:${toString cfg.port}:3010" ];
      environmentFiles = [ config.sops.templates."affine-env".path ];
      environment = {
        AFFINE_SERVER_EXTERNAL_URL = "https://${domain}";
        REDIS_SERVER_HOST = cfg.internalIp;
        REDIS_SERVER_PORT = "6379";
      };
      volumes = [
        "/var/lib/affine/storage:/root/.affine/storage"
        "/var/lib/affine/config:/root/.affine/config"
      ];
      extraOptions = [
        "--runtime=runc"
        "--security-opt=seccomp=unconfined"
      ];
    };

    # CRITICAL: Ensure migrations and databases are up before the container starts
    systemd.services."podman-affine" = {
      after = [
        "postgresql.service"
        "redis-affine.service"
        "affine-migration.service"
      ];
      requires = [
        "postgresql.service"
        "redis-affine.service"
        "affine-migration.service"
      ];
    };

    systemd.services.affine-migration = {
      description = "Run Affine database migrations";
      after = [
        "postgresql.service"
        "redis-affine.service"
      ];
      requires = [
        "postgresql.service"
        "redis-affine.service"
      ];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
      };
      script = ''
        ${pkgs.podman}/bin/podman run --rm \
          --name affine_migration \
          --runtime runc \
          --security-opt seccomp=unconfined \
          -e REDIS_SERVER_HOST=${cfg.internalIp} \
          -e REDIS_SERVER_PORT=6379 \
          --env-file ${config.sops.templates."affine-env".path} \
          ghcr.io/toeverything/affine:stable \
          node ./scripts/self-host-predeploy.js
      '';
    };

    # --- Persistence ---
    environment.persistence."/persistent" = lib.mkIf config.custom.profiles.impermanence.enable {
      directories = [
        "/var/lib/affine"
        "/var/lib/postgresql"
        "/var/lib/redis-affine"
      ];
    };

    # --- Firewall ---
    networking.firewall.interfaces."podman0".allowedTCPPorts = [
      5432
      6379
    ];
  };
}
