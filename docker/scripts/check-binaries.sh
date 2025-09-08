#!/usr/bin/env bash
# check-binaries.sh — confirm critical binaries exist and print versions

set -euo pipefail

bins=(convert rsvg-convert ffmpeg gs)
missing=()

echo "=== Binary Checks & Versions ==="

for b in "${bins[@]}"; do
  if command -v "$b" >/dev/null 2>&1; then
    case "$b" in
      convert)      echo "ImageMagick: $($b -version 2>/dev/null | awk 'NR==1{print $3}')" ;;
      rsvg-convert) echo "librsvg: $($b --version 2>/dev/null | tr -d '\n')" ;;
      ffmpeg)       echo "ffmpeg: $($b -version 2>/dev/null | head -1)" ;;
      gs)           echo "ghostscript: $($b --version 2>/dev/null)" ;;
      *)            echo "$b: installed ($(command -v "$b"))" ;;
    esac
  else
    missing+=("$b")
  fi
done

if ((${#missing[@]})); then
  echo "WARN(13): Missing binaries: ${missing[*]}"
else
  echo "OK: All required binaries are installed"
fi

exit 0

