#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

LIVE_FROM_START=false
PRETEND_MODE=false
 
usage() {
    echo "Usage: $0 [-l] <channel_name> <upload_channel_name> <output_path>"
    echo "  -l    Download live stream from the beginning (live-from-start mode)"
    echo "  -p    Do not download or upload, but prints and create files (pretend mode)"
    exit 1
}
 
while getopts ":lp" opt; do
    case $opt in
        l) LIVE_FROM_START=true ;;
        p) PRETEND_MODE=true ;;
        *) usage ;;
    esac
done

shift $((OPTIND - 1))
CHANNEL="${1:-}"
UPLOAD_CHANNEL="${2:-}"
OUTPUT_PATH="${3:-}"

if [ -z "$CHANNEL" ] || [ -z "$OUTPUT_PATH" ] || [ -z "$UPLOAD_CHANNEL" ]; then
    echo "Usage: $0 <channel_name> <upload_channel_name> <output_path>"
    exit 1
fi

LOGFILE="$SCRIPT_DIR/$CHANNEL.log"
exec >>"$LOGFILE" 2>&1

SCRIPT_NAME=$(basename "$0")
source "$(dirname "$0")/log.sh"


log "Starting archive pipeline for $CHANNEL, upload channel: $UPLOAD_CHANNEL, live from start: $LIVE_FROM_START"
tmpdir=$(mktemp -d -t twitch-archive-XXXXXX)
tmpdir_final=$(mktemp -d -t twitch-archive-XXXXXX)
log "Using temporary directory $tmpdir for intermediate files"
if [ "$PRETEND_MODE" = true ]; then
    log "Pretend mode enabled, using $tmpdir_final for final files"
fi

cleanup() {
    log "Cleaning up temporary directory"
	rm -rf "$tmpdir"
}

trap cleanup EXIT


# téléchargement
log "Downloading latest VOD"
DOWNLOAD_ARGS=("$CHANNEL" "$OUTPUT_PATH" "$tmpdir")
if [ "$LIVE_FROM_START" = true ]; then
    DOWNLOAD_ARGS=(-p "$DOWNLOAD_ARGS[@]")
fi
log "Download arguments: ${DOWNLOAD_ARGS[*]}"
if [ "$LIVE_FROM_START" = true ]; then
    "$SCRIPT_DIR/download.sh" -l "${DOWNLOAD_ARGS[@]}"
else
    "$SCRIPT_DIR/download.sh" "${DOWNLOAD_ARGS[@]}"
fi
log "Download finished"

data=$(cat "$tmpdir/metadata.json")
video_id=$(echo $data | jq '.id | tonumber')
title=$(echo $data | jq -r '.title')
creation_date=$(echo $data | jq -r '.created_at | split("T")[0]')
# TODO: change creation_date format to be coherent with channel (e.g. 2024-06-30 -> 30.06.2024)
creation_date_youtube=$(date -d "$creation_date" +"%d.%m.%Y")
day_english=$(date -d "$creation_date" +"%A")
day_french=$(case $day_english in
    Monday) echo "lundi" ;;
    Tuesday) echo "mardi" ;;
    Wednesday) echo "mercredi" ;;
    Thursday) echo "jeudi" ;;
    Friday) echo "vendredi" ;;
    Saturday) echo "samedi" ;;
    Sunday) echo "dimanche" ;;
esac)

# upload
log "Uploading VOD"
channel_link="https://twitch.tv/$CHANNEL"
files_dir="$SCRIPT_DIR/script_files"
upload_channel_dir="$files_dir/$UPLOAD_CHANNEL"
mkdir -p "$upload_channel_dir"
UPLOAD_ARGS=(-quiet -filename "$tmpdir/video."* -secrets "$upload_channel_dir/client_secrets.json" -cache "$upload_channel_dir/request.token" -title "$title - $creation_date_youtube" -recordingDate "$creation_date" -metaJSONout "$tmpdir/meta.out.json")

meta_json="$upload_channel_dir/meta.json"
resolved_meta="$tmpdir/resolved_meta.json"
if [ -f "$meta_json" ]; then
    log "Using custom metadata from $meta_json"
    jq --arg t "$title" --arg d "$creation_date_youtube" --arg f "$day_french" --arg c "$channel_link" 'walk(if type == "string" then gsub("{{title}}"; $t) | gsub("{{date}}"; $d) | gsub("{{day}}"; $f) | gsub("{{channel}}"; $c) else . end)' "$meta_json" > "$resolved_meta"
    # resolved_desc=$(jq -r '.description' "$meta_json" | jq -Rr --arg t "$title" --arg d "$creation_date_youtube" --arg f "$day_french" --arg c "$channel_link" 'gsub("{{title}}"; $t) | gsub("{{date}}"; $d) | gsub("{{day}}"; $f) | gsub("{{channel}}"; $c)')
    # UPLOAD_ARGS+=(-description "$resolved_desc" -metaJSON "$meta_json")
    UPLOAD_ARGS+=(-metaJSON "$meta_json")
else
    log "No custom metadata found, using default title and description"
    UPLOAD_ARGS+=(-description "VOD de $CHANNEL du $day_french $creation_date_youtube")
fi
if [ "$PRETEND_MODE" = true ]; then
    log "Pretend mode enabled, skipping actual upload"
    mv -v "$tmpdir/"* "$tmpdir_final/"
    log "Files created in $tmpdir_final, not deleted after script completion"
    exit 0
fi
"$SCRIPT_DIR"/youtubeuploader "${UPLOAD_ARGS[@]}"

log "Upload finished"

log "Moving data to archive directory"

output_path="$OUTPUT_PATH/$CHANNEL"
archive_dir="$output_path/$creation_date""_$video_id"
mkdir -p "$archive_dir"
mv -v "$tmpdir/"* "$archive_dir/"

log "Pipeline completed"
