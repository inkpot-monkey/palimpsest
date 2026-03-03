{
  writeShellApplication,
  grim,
  slurp,
  coreutils,
  wl-clipboard,
  libnotify,
  gnused,
  ollama,
  curl,
}:

writeShellApplication {
  name = "ocrShot";

  runtimeInputs = [
    grim
    slurp
    coreutils
    wl-clipboard
    libnotify
    gnused
    ollama
    curl
  ];

  text = ''
    # 1. Pre-flight Check
    if ! curl --silent --fail --max-time 1 "http://localhost:11434/" > /dev/null; then
      notify-send -u critical "OCR Offline" "Ollama service is down."
      exit 1
    fi

    # 2. Capture area
    AREA=$(slurp) || exit 0
    TEMP_IMG=$(mktemp --suffix=.png)
    grim -g "$AREA" "$TEMP_IMG"

    notify-send "Vision OCR" "Extracting text..."

    # 3. The Universal Prompt
    TARGET_MODEL="''${OLLAMA_VISION_MODEL:-llama3.2-vision}"

    # We removed "Spanish" and instructed it to use the original language.
    # We still tell it to fix typos based on the context of whatever language it detects.
    PROMPT="Extract the text from this image exactly as written in its original language. Ignore background art, debris, and action lines. Fix any typos caused by bad scanning to form valid syntax in that language. Output ONLY the raw extracted text. Do not translate it. No quotes, no explanations, no conversational filler."

    # 4. Execute
    CLEAN_TEXT=$(ollama run "$TARGET_MODEL" "$PROMPT $TEMP_IMG" 2>/dev/null)
    rm "$TEMP_IMG"
    CLEAN_TEXT=$(echo "$CLEAN_TEXT" | sed 's/^ *//;s/ *$//')

    if [ -z "$CLEAN_TEXT" ]; then
      notify-send -u critical "OCR Failed" "No text recognized."
      exit 1
    fi

    # 5. Final Output
    printf "%s" "$CLEAN_TEXT" | wl-copy
    notify-send "OCR Captured" "$CLEAN_TEXT"
  '';
}
