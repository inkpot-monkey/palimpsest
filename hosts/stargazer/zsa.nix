{
  pkgs,
  ...
}:

{
  hardware.keyboard.zsa.enable = true;
  environment.systemPackages = with pkgs; [ wally-cli ];
  users.extraGroups.plugdev.members = [ "inkpotmonkey" ];
}
