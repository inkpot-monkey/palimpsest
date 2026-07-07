{ self, inputs, ... }:
{
  perSystem =
    { pkgs, ... }:
    let
      pushRelay = import ./push-relay { inherit pkgs self; };
    in
    {
      apps = {
        dns = import ./dns { inherit pkgs self inputs; };
        tailscale-dns = import ./tailscale-dns { inherit pkgs self; };
        build-pi = import ./build-pi { inherit pkgs self; };
        push-relay-deploy = {
          type = "app";
          program = "${pushRelay.deploy}/bin/push-relay-deploy";
        };
      };
      devShells.push-relay = pushRelay.devShell;
    };
}
