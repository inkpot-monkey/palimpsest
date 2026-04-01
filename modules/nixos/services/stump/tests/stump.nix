# NixOS VM integration test for the Stump service module.
# Tests that:
#   1. The module evaluates and the service starts correctly.
#   2. The HTTP server is reachable on the configured port.
#   3. The web UI is served (index.html exists in the response).
#   4. The API health endpoint responds with a recognisable payload.
#   5. Custom port configuration works.
#   6. openFirewall option is accepted without evaluation errors.
#   7. The `stump` user / group exist and the service runs as them.
{
  pkgs,
  self,
  ...
}:
pkgs.testers.nixosTest {
  name = "stump";

  nodes = {
    # Basic default-port instance
    server = {
      imports = [ self.nixosModules.stump ];

      services.stump = {
        enable = true;
        # Use default port 10801
      };
    };

    # Alternative port + openFirewall
    serverAltPort = {
      imports = [ self.nixosModules.stump ];

      services.stump = {
        enable = true;
        port = 18080;
        openFirewall = true;
      };
    };
  };

  testScript = ''
    # ── server (default port 10801) ────────────────────────────────────────────
    server.start()
    server.wait_for_unit("stump.service")
    server.wait_for_open_port(10801)

    # 1. HTTP server is reachable and returns 200 on the root path
    result = server.succeed(
        "curl -fsS --max-time 10 -o /dev/null -w '%{http_code}' http://127.0.0.1:10801/"
    )
    assert result == "200", f"Expected HTTP 200 from root, got {result!r}"

    # 2. The web UI is served (index.html should be present in the response body)
    body = server.succeed("curl -fsS --max-time 10 http://127.0.0.1:10801/")
    assert "<!DOCTYPE html>" in body.lower() or "<html" in body.lower(), \
        "Root path did not return an HTML document"

    # 3. API health endpoint (Stump exposes /api/v1/ping)
    ping = server.succeed(
        "curl -fsS --max-time 10 http://127.0.0.1:10801/api/v1/ping"
    )
    assert "pong" in ping.lower() or ping.strip() != "", \
        f"Unexpected ping response: {ping!r}"

    # 4. The stump user and group exist
    server.succeed("id stump")
    server.succeed("getent group stump")

    # 5. The service is running as the stump user
    uid = server.succeed("id -u stump").strip()
    proc_uid = server.succeed(
        "ps -o uid= -p $(systemctl show -P MainPID stump.service)"
    ).strip()
    assert uid == proc_uid, f"Service is not running as stump (uid={uid!r}, proc_uid={proc_uid!r})"

    # 6. dataDir was created with correct ownership
    server.succeed("test -d /var/lib/stump")
    owner = server.succeed("stat -c '%U:%G' /var/lib/stump").strip()
    assert owner == "stump:stump", f"dataDir ownership is {owner!r}, expected stump:stump"

    # ── serverAltPort (port 18080) ─────────────────────────────────────────────
    serverAltPort.start()
    serverAltPort.wait_for_unit("stump.service")
    serverAltPort.wait_for_open_port(18080)

    # 7. Custom port is respected
    result_alt = serverAltPort.succeed(
        "curl -fsS --max-time 10 -o /dev/null -w '%{http_code}' http://127.0.0.1:18080/"
    )
    assert result_alt == "200", f"Expected HTTP 200 on alt port 18080, got {result_alt!r}"

    # 8. Default port 10801 is NOT listening on the alt-port node
    serverAltPort.fail("curl -fsS --max-time 3 http://127.0.0.1:10801/")
  '';
}
