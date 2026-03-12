#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

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


log "Starting archive pipeline for $CHANNEL"
tmpdir=$(mktemp -d -t twitch-archive-XXXXXX)
log "Using temporary directory $tmpdir for intermediate files"

cleanup() {
    log "Cleaning up temporary directory"
	rm -rf "$tmpdir"
}

trap cleanup EXIT



# téléchargement
log "Downloading latest VOD"
"$SCRIPT_DIR/download_from_live.sh" "$CHANNEL" "$OUTPUT_PATH" "$tmpdir"

log "Download finished"

data=$(cat "$tmpdir/metadata.json")
video_id=$(echo $data | jq '.id | tonumber')
title=$(echo $data | jq -r '.title')
creation_date=$(echo $data | jq -r '.created_at | split("T")[0]')

# upload
log "Uploading VOD"
# "$SCRIPT_DIR/upload-vod.sh" "$CHANNEL"
./youtubeuploader -quiet -filename "$tmpdir/video."* -secrets "$SCRIPT_DIR/client_secrets_$UPLOAD_CHANNEL.json" -cache "$SCRIPT_DIR/request_$UPLOAD_CHANNEL.token" -title "$title - $creation_date" -description "Archived Twitch stream from $creation_date with id $video_id"

log "Upload finished"

log "Moving data to archive directory"

output_path="$OUTPUT_PATH/$CHANNEL"
archive_dir="$output_path/$creation_date""_$video_id"
mkdir -p "$archive_dir"
mv -v "$tmpdir/"* "$archive_dir/"

log "Pipeline completed"
