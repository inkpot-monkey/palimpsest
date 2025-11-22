{ inputs, outputs, lib, residents, self, ... }:

let
  inherit (lib.lists) forEach;
  inherit (lib.attrsets) mergeAttrsList;
in {
  imports = [ inputs.home-manager.nixosModules.home-manager ];



  home-manager = {
    useUserPackages = true;
    useGlobalPkgs = true;
    extraSpecialArgs = { inherit inputs outputs residents self; };
    backupFileExtension = "backup";

    users = mergeAttrsList (forEach residents
      (resident: { ${resident.settings.username} = resident.config; }));
  };

  users.users = mergeAttrsList (forEach residents (resident:
    let inherit (resident.settings) username hashedPassword extraGroups;
    in {
      ${username} = {
        isNormalUser = true;
        inherit hashedPassword;
        inherit extraGroups;
      };
    }));

  users.groups = {
    libvirt.members = [ ];
    podman.members = [ ];
    uinput.members = [ ];
  };

}
