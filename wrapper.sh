#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

LIVE_FROM_START=false
PRETEND_MODE=false
TRIM_SECONDS=0
 
usage() {
    echo "Usage: $0 [-l] [-p] [-t <seconds>] <channel_name> <upload_channel_name> <output_path>"
    echo "  -l             Download live stream from the beginning (live-from-start mode)"
    echo "  -p             Do not download or upload, but prints and create files (pretend mode)"
    echo "  -t <seconds>   Also upload a trimmed version with the first N seconds removed"
    exit 1
}
 
while getopts ":lpt:" opt; do
    case $opt in
        l) LIVE_FROM_START=true ;;
        p) PRETEND_MODE=true ;;
        t) TRIM_SECONDS="$OPTARG" ;;
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
log "Using temporary directory $tmpdir for intermediate files"
if [ "$PRETEND_MODE" = true ]; then
    tmpdir_final=$(mktemp -d -t twitch-archive-XXXXXX)
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
if [ "$PRETEND_MODE" = true ]; then
    DOWNLOAD_ARGS=(-p "${DOWNLOAD_ARGS[@]}")
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

meta_json="$upload_channel_dir/meta.json"

# Helper: resolve metadata template to a given output path
resolve_meta() {
    local out_path="$1"
    if [ -f "$meta_json" ]; then
        jq --arg t "$title" --arg d "$creation_date_youtube" --arg f "$day_french" --arg c "$channel_link" \
            'walk(if type == "string" then gsub("{{title}}"; $t) | gsub("{{date}}"; $d) | gsub("{{day}}"; $f) | gsub("{{channel}}"; $c) else . end)' \
            "$meta_json" > "$out_path"
    fi
}
 
UPLOAD_ARGS_BASIS=(-quiet -secrets "$files_dir/client_secrets.json" -cache "$upload_channel_dir/request.token" -recordingDate "$creation_date")

# --- Upload full version ---
log "Uploading full VOD"
resolved_meta="$tmpdir/resolved_meta.json"
resolve_meta "$resolved_meta"
full_video_file=$(echo "$tmpdir/video."*)
 
if [ "$PRETEND_MODE" = true ]; then
    log "Pretend mode: skipping full upload"
else
    UPLOAD_ARGS=("${UPLOAD_ARGS_BASIS[@]}" -filename "$full_video_file" -metaJSONout "$tmpdir/meta.out.json")
    if [ -f "$meta_json" ]; then
        UPLOAD_ARGS+=(-metaJSON "$resolved_meta")
    else
        UPLOAD_ARGS+=(-description "VOD de $CHANNEL du $day_french $creation_date_youtube" -title "$title - $creation_date_youtube")
    fi
    "$SCRIPT_DIR"/youtubeuploader "${UPLOAD_ARGS[@]}"
    log "Full upload finished"
fi

# --- Trimmed version ---
if [ "$TRIM_SECONDS" -gt 0 ] 2>/dev/null; then
    video_ext="${full_video_file##*.}"
    trimmed_video_file="$tmpdir/video_trimmed.$video_ext"
    trim_label=" [sans intro]"
 
    log "Trimming first ${TRIM_SECONDS}s with ffmpeg (stream copy, no re-encode)"
    ffmpeg -loglevel warning -ss "$TRIM_SECONDS" -i "$full_video_file" -c copy "$trimmed_video_file"
    log "Trim complete: $trimmed_video_file"
 
    log "Uploading trimmed VOD"
    if [ "$PRETEND_MODE" = true ]; then
        log "Pretend mode: skipping trimmed upload"
    else
        UPLOAD_ARGS_TRIMMED=("${UPLOAD_ARGS_BASIS[@]}" -filename "$trimmed_video_file")
        if [ -f "$meta_json" ]; then
            UPLOAD_ARGS_TRIMMED+=(-metaJSON "$resolved_meta")
        else
            UPLOAD_ARGS_TRIMMED+=(-description "VOD de $CHANNEL du $day_french $creation_date_youtube${trim_label}" -title "$title - $creation_date_youtube${trim_label}")
        fi
        "$SCRIPT_DIR"/youtubeuploader "${UPLOAD_ARGS_TRIMMED[@]}"
        log "Trimmed upload finished"
    fi
fi

# --- Move full VOD + metadata to local archive (trimmed version not archived) ---
if [ "$PRETEND_MODE" = true ]; then
    log "Pretend mode enabled, moving files to $tmpdir_final"
    mv -v "$tmpdir/"* "$tmpdir_final/"
    log "Files in $tmpdir_final, not deleted after script completion"
    exit 0
fi
 
log "Moving data to archive directory"
rm -f "$tmpdir/resolved_meta.json" "$tmpdir/video_trimmed."*
output_path="$OUTPUT_PATH/$CHANNEL"
archive_dir="$output_path/$creation_date""_$video_id"
mkdir -p "$archive_dir"
mv -v "$tmpdir/"* "$archive_dir/"
 
log "Pipeline completed"