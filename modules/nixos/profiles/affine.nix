{
  config,
  lib,
  settings,
  ...
}:
let
  domain = "affine.${config.networking.domain}";
  inherit (settings.services.private.affine) port;
in
{
  # Assume you have this defined in your flake
  # imports = [ self.nixosProfiles.podman ];

  # --- Secrets & Templates ---
  sops.secrets.affine_db_password = {
    owner = "postgres";
  };

  sops.templates."affine-env" = {
    content = ''
      DATABASE_URL=postgresql://affine:${config.sops.placeholder.affine_db_password}@${config.host.containers.internal}:5432/affine
    '';
  };

  # --- Database (PostgreSQL) ---
  services.postgresql = {
    enable = true;
    enableTCPIP = true; # CRITICAL: Allow TCP connections

    settings = {
      # Bind to all addresses but restrict via firewall.
      # This avoids "Cannot assign requested address" if the podman bridge isn't up yet.
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
    echo "ALTER ROLE affine WITH PASSWORD '$(cat ${config.sops.secrets.affine_db_password.path})';" > $TEMP_SQL

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
    # Assuming the container runs as root. If it runs as a non-root user (like UID 1000),
    # change 'root root' to '1000 1000' to prevent EACCES errors.
    "d /var/lib/affine/storage 0755 root root -"
    "d /var/lib/affine/config 0755 root root -"
  ];

  virtualisation.oci-containers.containers.affine = {
    image = "ghcr.io/toeverything/affine-graphql:stable";
    # CRITICAL: Bind to 127.0.0.1 to prevent exposing the raw backend to the internet
    ports = [ "127.0.0.1:${toString port}:3010" ];
    environmentFiles = [ config.sops.templates."affine-env".path ];
    environment = {
      AFFINE_SERVER_EXTERNAL_URL = "https://${domain}";
      REDIS_SERVER_HOST = config.host.containers.internal;
      REDIS_SERVER_PORT = "6379";
    };
    volumes = [
      "/var/lib/affine/storage:/root/.affine/storage"
      "/var/lib/affine/config:/root/.affine/config"
    ];
  };

  # CRITICAL: Ensure databases are up before the container starts to prevent crash loops
  systemd.services."podman-affine" = {
    after = [
      "postgresql.service"
      "redis-affine.service"
    ];
    requires = [
      "postgresql.service"
      "redis-affine.service"
    ];
  };

  # --- Network & Proxy ---

  # --- Persistence ---
  environment.persistence."/persistent" = {
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
}
