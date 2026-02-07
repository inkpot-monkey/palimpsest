#!/usr/bin/env bash

# Enable "nullglob" so *.mkv doesn't crash if no files exist
shopt -s nullglob

convert_file() {
  local input="$1"
  local filename
  filename=$(basename -- "$input")
  
  # Strip extension to get the base name (e.g., "Movie.mkv" -> "Movie")
  local base="${filename%.*}"
  local output_file="${base}.av1.mkv"
  
  # CHECK 1: Is the input file ITSELF an AV1 file?
  # (Prevents accidentally processing the files we just created)
  if [[ "$filename" == *".av1.mkv" ]]; then
    # Silently skip to avoid spamming the logs
    return
  fi

  # CHECK 2: Does the target output file ALREADY exist?
  if [ -e "$output_file" ]; then
    echo "Skipping: $input (Target '$output_file' already exists)"
    return
  fi

  echo "Converting: $input -> $output_file"
  
  ffmpeg -i "$input" \
    -c:v libsvtav1 -preset 8 -crf 35 \
    -c:a copy \
    -c:s copy \
    -n "$output_file" < /dev/null
    # < /dev/null is a safety trick: it prevents ffmpeg from swallowing 
    # the loop's input if something goes weird in a batch process
}

# CASE 1: Specific files provided
if [ "$#" -gt 0 ]; then
  for file in "$@"; do
    convert_file "$file"
  done

# CASE 2: No args, scan directory
else
  echo "Scanning current directory for new video files..."
  for file in *.mkv *.mp4 *.webm *.avi; do
    [ -e "$file" ] || continue
    convert_file "$file"
  done
fi
