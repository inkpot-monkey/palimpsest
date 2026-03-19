set -e

VIDEO_FILE="$1"
# The IP and Port of the transcription server
LAPTOP_IP="@TRANSCRIPTION_SERVER_ADDRESS@" 
PORT="@TRANSCRIPTION_SERVER_PORT@"
LANGUAGE="@LANGUAGE@"

if [ -z "$VIDEO_FILE" ]; then exit 1; fi
if [ ! -f "$VIDEO_FILE" ]; then exit 1; fi

# Mime-type check
MIME_TYPE=$(file --mime-type -b "$VIDEO_FILE")
if [[ ! "$MIME_TYPE" =~ ^video/ ]]; then
  echo "❌ Skipping non-video file: $VIDEO_FILE ($MIME_TYPE)"
  exit 0
fi

BASENAME="${VIDEO_FILE%.*}"
SRT_FILE="${BASENAME}.srt"

if [ -f "$SRT_FILE" ]; then exit 0; fi

# Find the specified language track
TRACK_INDEX=$(ffprobe -v error -select_streams "a:m:language:$LANGUAGE" -show_entries stream=index -of json "$VIDEO_FILE" | jq -r '.streams[0].index // empty')
MAP_ARG=${TRACK_INDEX:-"0"}
MAP_CMD="0:a:$MAP_ARG"

echo "🚀 Streaming audio to the Systemd Socket API ($LANGUAGE)..."

# The Zero-Trust TCP Pipeline
# We use nc -q 5 to wait for EOF and then close
# We check the size of the output SRT file
ffmpeg -v error -y -i "$VIDEO_FILE" -map "$MAP_CMD" -ac 1 -c:a libopus -b:a 32k -f ogg pipe:1 | \
nc -q 5 "$LAPTOP_IP" "$PORT" > "$SRT_FILE"

if [ ! -s "$SRT_FILE" ]; then
  echo "❌ Error: Generated SRT file is empty. Server might be down."
  rm -f "$SRT_FILE"
  exit 1
fi

echo "✅ Subtitles generated: $SRT_FILE"
