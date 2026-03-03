#!/usr/bin/env bash
set -e

VIDEO_FILE="$1"

# Validation
if [ -z "$VIDEO_FILE" ]; then
    echo "Error: Missing video file." >&2
    echo "Usage: auto-sub <video_file>" >&2
    exit 1
fi

BASENAME="${VIDEO_FILE%.*}"
SRT_FILE="${BASENAME}.srt"

# Idempotency Check
if [ -f "$SRT_FILE" ]; then
    echo "⏩ SKIPPING: $SRT_FILE already exists."
    exit 0
fi

echo "Processing: $VIDEO_FILE"

# 1. Get Track Info safely
TRACK_INDEX=$(ffprobe -v error -select_streams a:m:language:spa \
    -show_entries stream=index -of json "$VIDEO_FILE" | jq -r '.streams[0].index // empty')

if [ -z "$TRACK_INDEX" ]; then
    echo "⚠️  Warning: No 'spa' track found. Defaulting to the first audio track."
    MAP_ARG="0:a:0"
else
    echo "✅ Using Spanish Track Index: $TRACK_INDEX"
    MAP_ARG="0:$TRACK_INDEX"
fi

# 2. Setup a temporary directory with a trap
# We use a directory now because WhisperX generates output files automatically
TMP_DIR=$(mktemp -d /tmp/auto-sub-XXXXXX)
TMP_WAV="$TMP_DIR/audio.wav"
trap 'rm -rf "$TMP_DIR"' EXIT INT TERM

echo "⏳ Extracting audio track..."
ffmpeg -v error -y -i "$VIDEO_FILE" -map "$MAP_ARG" -ar 16000 -ac 1 -c:a pcm_s16le "$TMP_WAV"

echo "🤖 Running WhisperX locally (Transcription + VAD + Alignment)..."
# 3. Execute WhisperX
# Note: --compute_type int8 reduces memory usage significantly without losing accuracy
whisperx "$TMP_WAV" \
    --model large-v3 \
    --language es \
    --compute_type int8 \
    --output_format srt \
    --output_dir "$TMP_DIR"

# 4. Move the generated subtitle to the final destination
# WhisperX names the output file after the input file (audio.wav -> audio.srt)
mv "$TMP_DIR/audio.srt" "$SRT_FILE"

echo -e "\n🎉 Done! Perfectly aligned subtitles saved to: $SRT_FILE"
