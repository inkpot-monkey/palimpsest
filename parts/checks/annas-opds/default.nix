{ pkgs, ... }:

let
  annasOpds = pkgs.annas_opds;
in

pkgs.testers.nixosTest {
  name = "annas-opds-smoke";

  nodes.machine = {
    environment.systemPackages = [
      annasOpds
      pkgs.curl
    ];
  };

  testScript = ''
    machine.start()
    machine.wait_for_unit("network-online.target")

    machine.succeed(
      "export BIND_ADDR=127.0.0.1:19999 ANNAS_SEARCH_MODE=mock BOOKS_DIR=/tmp/annas-books; "
      + "mkdir -p /tmp/annas-books; "
      + "nohup ${annasOpds}/bin/annas-opds > /tmp/annas-opds.log 2>&1 & sleep 2"
    )
    machine.wait_for_open_port(19999)

    out = machine.succeed("curl -fsS 'http://127.0.0.1:19999/opds/search?query=test'")
    assert "mockdeadbeef" in out
    assert "application/opds+json" in out
  '';
}
