{ pkgs, ... }:

{
  home.file.".config/kanata/kanata.kbd".source = ./configs/kanata.kbd;
  systemd.user.services.kanata = {
    Unit.Description = "Kanata software keyboard remapper";
    Install.WantedBy = [ "graphical-session.target" ];
    Service = {
      ExecStart = "${pkgs.kanata}/bin/kanata -c ${./configs/kanata.kbd}";
    };
  };
}
