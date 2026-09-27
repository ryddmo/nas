#!/bin/sh
# Scans a media library and reports video/audio codec per file, one line each:
#   <videocodec>|<audiocodec>|<path>
#
# Written for the DS214play, which has no ffprobe/mediainfo — only a stripped-down
# /usr/bin/ffmpeg (thumbnail-generation build). `ffmpeg -i <file>` reads just the
# container header, so this is fast even on weak hardware; it does not transcode
# or touch the file.
#
# Run ON the NAS, e.g. from the Mac without copying the file over first:
#   ssh ds214play 'sh -s' < scripts/scan-plex-codecs.sh
#
# Then pull the results back and clean up (the NAS has very little free RAM/disk
# headroom, don't leave scratch files sitting in Plex's AppData):
#   ssh ds214play "cat /volume1/PlexMediaServer/AppData/codec_scan_results.txt" > /tmp/codec_scan_results.txt
#   ssh ds214play "rm -f /volume1/PlexMediaServer/AppData/codec_scan_results.txt"
#
# Quick analysis once you have the results locally:
#   awk -F'|' '{print $1}' /tmp/codec_scan_results.txt | sort | uniq -c | sort -rn   # video codec counts
#   awk -F'|' '{print $2}' /tmp/codec_scan_results.txt | sort | uniq -c | sort -rn   # audio codec counts
#   grep '^hevc|' /tmp/codec_scan_results.txt | cut -d'|' -f3                        # list HEVC files
#
# Usage: ./scan-plex-codecs.sh [media_root] [output_file]

MEDIA_ROOT="${1:-/volume1/Media}"
OUT="${2:-/volume1/PlexMediaServer/AppData/codec_scan_results.txt}"

> "$OUT"
find "$MEDIA_ROOT" -type f \( -iname "*.mkv" -o -iname "*.mp4" -o -iname "*.avi" -o -iname "*.m4v" -o -iname "*.wmv" -o -iname "*.ts" \) | while IFS= read -r f; do
  info=$(ffmpeg -i "$f" 2>&1)
  vline=$(echo "$info" | grep -m1 "Video:")
  aline=$(echo "$info" | grep -m1 "Audio:")
  vcodec=$(echo "$vline" | sed -E "s/.*Video: ([A-Za-z0-9_]+).*/\1/")
  acodec=$(echo "$aline" | sed -E "s/.*Audio: ([A-Za-z0-9_]+).*/\1/")
  echo "${vcodec}|${acodec}|${f}" >> "$OUT"
done
echo DONE >> "$OUT"
