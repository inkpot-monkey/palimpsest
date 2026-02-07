{ writeShellApplication, ffmpeg }:

writeShellApplication {
  name = "to-av1";

  # Automatically puts ffmpeg in the $PATH for the script
  runtimeInputs = [ ffmpeg ];

  # Read the text directly from your external file
  text = builtins.readFile ./to-av1.sh;
}
