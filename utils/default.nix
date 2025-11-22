{ lib }:
let
  # Reference: https://gist.github.com/CMCDragonkai/de84aece83f8521d087416fa21e34df4

  inherit (builtins) attrNames readDir;
  inherit (lib) genAttrs;
  inherit (lib.attrsets) filterAttrs;

  # Make sure we are only importing directories
  getDirs = dir:
    attrNames (filterAttrs (name: value: value == "directory") (readDir dir));

  importTemplates = genAttrs (getDirs ../templates) (name: {
    path = ../templates + "/${name}";
    description = "A ${name} project template";
  });

  importHomes =
    genAttrs (getDirs ../users) (name: import ../users/${name}/home.nix);

in { inherit importTemplates importHomes; }
