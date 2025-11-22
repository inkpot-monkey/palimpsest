{ jre, makeWrapper, maven, xmlstarlet, runCommand }:
let
  parser = runCommand "parser" { } ''
    #!/usr/bin/env nix
    //! ```cargo
    //! [dependencies]
    //! time = "0.1.25"
    //! ```
    /*
    #!nix shell nixpkgs#rustc nixpkgs#rust-script nixpkgs#cargo --command rust-script
    */
    use std::fs;

    fn main() {
      let out_dir = env!("out");
      fs::create_dir(out_dir)?;

          let path = "pom.toml";

    let mut output = File::create(path)?;
    write!(output, "pname=\"test\"\nversion=\"test\"")?;

    Ok(())
   }
'';
  
  pom-parser = runCommand "pom-parser" { } ''
    mkdir $out
    touch pom.toml

    echo "pname=\"$(${xmlstarlet}/bin/xml sel -t -m _:project -v _:artifactId ${./pom.xml})\"" >> pom.toml

    echo "version=\"$(${xmlstarlet}/bin/xml sel -t -m _:project -v _:version ${./pom.xml})\"" >> pom.toml

    mv pom.toml $out
  '';

  packageDetails = (builtins.fromTOML (builtins.readFile "${parser}/pom.toml"));

  inherit (packageDetails) pname version;
in maven.buildMavenPackage {
  inherit pname version;

  src = ./.;

  mvnHash = "sha256-f0/u1oWTVrxNCviShqBpRZjkxXzpa0sYwWrCWeI1hoo=";

  nativeBuildInputs = [ makeWrapper ];

  installPhase = ''
    mkdir -p $out/bin $out/share/${pname}

    install -Dm644 target/${pname}-${version}.jar $out/share/${pname}

    makeWrapper ${jre}/bin/java $out/bin/${pname} \
     --add-flags "-jar $out/share/${pname}/${pname}-${version}.jar"
  '';
}
