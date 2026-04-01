#!/usr/bin/env bash
# Stop si erreur pas handled, erreur si var non def
# pipefail arrête le script si cmd1 dans cmd1 | jq cause une erreur, évitant des comportement indet
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT_NAME=$(basename "$0")

PRETEND_MODE=false
TRIM_SECONDS=0

usage() {
    echo "Usage: $0 [-p] [-t <seconds>] <channel_name> <upload_channel_name> <output_path>"
    echo "  -p             Do not download or upload, but print and create files (pretend mode)"
    echo "  -t <seconds>   Also upload a trimmed version with the first N seconds removed"
    exit 1
}

while getopts ":pt:" opt; do
    case $opt in
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
    usage
fi

LOGFILE="$SCRIPT_DIR/$CHANNEL.log"
exec >>"$LOGFILE" 2>&1

source "$(dirname "$0")/log.sh"

# ── Single-instance lock — prevents concurrent cron runs ───────────────────────
exec 9>"$SCRIPT_DIR/$CHANNEL.lock"
if ! flock -n 9; then
    log "Another instance is already running, exiting"
    exit 1
fi

files_dir="$SCRIPT_DIR/script_files"
channel_dir="$files_dir/$CHANNEL"
mkdir -p "$channel_dir"

log "Starting archive pipeline for $CHANNEL, upload channel: $UPLOAD_CHANNEL"

# ── Tmpdir for video downloads ─────────────────────────────────────────────────
tmpdir=$(mktemp -d -t twitch-archive-XXXXXX)
log "Using temporary directory $tmpdir"

cleanup() {
    log "Cleaning up temporary directory"
    rm -rf "$tmpdir"
}
trap cleanup EXIT

# ── Channel ID (cached) ────────────────────────────────────────────────────────
channel_info_file="$channel_dir/id.json"
if [ ! -f "$channel_info_file" ]; then
    log "Getting id of channel $CHANNEL"
    raw_data=$("$SCRIPT_DIR"/twitch api get /users -q login=$CHANNEL)
    if echo "$raw_data" | jq -e 'isempty(.data[])' >/dev/null; then
        log "Error fetching user's id"
        exit 1
    fi
    echo "$raw_data" > "$channel_info_file"
else
    log "Using cached info for channel $CHANNEL"
    raw_data=$(cat "$channel_info_file")
fi

user_id=$(echo "$raw_data" | jq '.data[].id | tonumber')

# ── Live check — skip while streaming, VOD will be available afterwards ────────
is_live=$("$SCRIPT_DIR"/twitch api get /streams -q user_id=$user_id | jq 'isempty(.data[]) | not')
[ "$is_live" = true ] && log "Currently streaming, skipping (will be archived later)" && exit 1
log "Not currently streaming"

# ── Archived video ID registry (JSON array) ───────────────────────────────────
archived_video_ids_file="$channel_dir/archived_video_ids.json"
[ ! -f "$archived_video_ids_file" ] && echo '[]' > "$archived_video_ids_file" && log "Created new archived_video_ids file"

# ── Fetch up to 20 recent VODs — catches split-stream parts ───────────────────
log "Fetching recent VODs"
raw_videos=$("$SCRIPT_DIR"/twitch api get /videos -q type=archive -q first=20 -q user_id=$user_id)
if echo "$raw_videos" | jq -e 'isempty(.data[])' >/dev/null; then
    log "No VODs found for channel $CHANNEL"
    exit 1
fi

# ── Filter out already-archived VODs ──────────────────────────────────────────
new_videos=$(echo "$raw_videos" | jq --slurpfile seen "$archived_video_ids_file" '
    [ .data[] | select(.id as $id | $seen[0] | index($id) == null) ]
')

new_count=$(echo "$new_videos" | jq 'length')
log "$new_count new VOD(s) to process"
[ "$new_count" -eq 0 ] && log "All recent VODs already archived, nothing to do" && exit 0

# ── Upload channel setup ───────────────────────────────────────────────────────
upload_channel_dir="$files_dir/$UPLOAD_CHANNEL"
mkdir -p "$upload_channel_dir"
meta_json="$upload_channel_dir/meta.json"

resolve_meta() {
    local title="$1" creation_date_youtube="$2" day_french="$3" channel_link="$4" out_path="$5"
    if [ -f "$meta_json" ]; then
        jq --arg t "$title" --arg d "$creation_date_youtube" --arg f "$day_french" --arg c "$channel_link" \
            'walk(if type == "string" then gsub("{{title}}"; $t) | gsub("{{date}}"; $d) | gsub("{{day}}"; $f) | gsub("{{channel}}"; $c) else . end)' \
            "$meta_json" > "$out_path"
    fi
}

# ── Process each VOD ──────────────────────────────────────────────────────────
for i in $(seq 0 $((new_count - 1))); do
    data=$(echo "$new_videos" | jq ".[$i]")
    video_id=$(echo "$data" | jq -r '.id')
    title=$(echo "$data" | jq -r '.title')
    creation_date=$(echo "$data" | jq -r '.created_at | split("T")[0]')
    creation_date_youtube=$(date -d "$creation_date" +"%d.%m.%Y")
    day_english=$(date -d "$creation_date" +"%A")
    day_french=$(case $day_english in
        Monday)    echo "lundi"    ;;
        Tuesday)   echo "mardi"    ;;
        Wednesday) echo "mercredi" ;;
        Thursday)  echo "jeudi"    ;;
        Friday)    echo "vendredi" ;;
        Saturday)  echo "samedi"   ;;
        Sunday)    echo "dimanche" ;;
    esac)
    channel_link="https://twitch.tv/$CHANNEL"

    log "── Processing VOD $video_id: $title ($creation_date) ──"

    vod_tmpdir="$tmpdir/vod_$video_id"
    mkdir -p "$vod_tmpdir"

    # ── Download ──────────────────────────────────────────────────────────────
    if [ "$PRETEND_MODE" = true ]; then
        log "Pretend mode: skipping download for VOD $video_id"
        full_video_file="$vod_tmpdir/video.mkv"   # placeholder
    else
        log "Downloading VOD $video_id"
        ~/.local/bin/yt-dlp "https://twitch.tv/videos/$video_id" \
            -N 4 --progress-delta 15 --no-part --newline \
            -o "$vod_tmpdir/video.%(ext)s"
        full_video_file=$(echo "$vod_tmpdir/video."*)
        log "Download complete: $full_video_file"
    fi

    # ── Upload full version ────────────────────────────────────────────────────
    resolved_meta="$vod_tmpdir/resolved_meta.json"
    resolve_meta "$title" "$creation_date_youtube" "$day_french" "$channel_link" "$resolved_meta"

    UPLOAD_ARGS_BASIS=(-quiet
        -secrets "$files_dir/client_secrets.json"
        -cache   "$upload_channel_dir/request.token"
        -recordingDate "$creation_date")

    if [ "$PRETEND_MODE" = true ]; then
        log "Pretend mode: skipping full upload for VOD $video_id"
    else
        log "Uploading full VOD $video_id"
        UPLOAD_ARGS=("${UPLOAD_ARGS_BASIS[@]}" -filename "$full_video_file" -metaJSONout "$vod_tmpdir/meta.out.json")
        if [ -f "$meta_json" ]; then
            UPLOAD_ARGS+=(-metaJSON "$resolved_meta")
        else
            UPLOAD_ARGS+=(-description "VOD de $CHANNEL du $day_french $creation_date_youtube" \
                          -title "$title - $creation_date_youtube")
        fi
        "$SCRIPT_DIR"/youtubeuploader "${UPLOAD_ARGS[@]}"
        log "Full upload finished for VOD $video_id"
    fi

    # ── Trimmed version (optional) ─────────────────────────────────────────────
    if [ "$TRIM_SECONDS" -gt 0 ] 2>/dev/null; then
        video_ext="${full_video_file##*.}"
        trimmed_video_file="$vod_tmpdir/video_trimmed.$video_ext"
        trim_label=" [sans intro]"

        if [ "$PRETEND_MODE" = true ]; then
            log "Pretend mode: skipping trim/upload for VOD $video_id"
        else
            log "Trimming first ${TRIM_SECONDS}s of VOD $video_id"
            ffmpeg -loglevel warning -ss "$TRIM_SECONDS" -i "$full_video_file" -c copy "$trimmed_video_file"
            log "Trim complete: $trimmed_video_file"

            log "Uploading trimmed VOD $video_id"
            UPLOAD_ARGS_TRIMMED=("${UPLOAD_ARGS_BASIS[@]}" -filename "$trimmed_video_file")
            if [ -f "$meta_json" ]; then
                UPLOAD_ARGS_TRIMMED+=(-metaJSON "$resolved_meta")
            else
                UPLOAD_ARGS_TRIMMED+=(-description "VOD de $CHANNEL du $day_french $creation_date_youtube${trim_label}" \
                                      -title "$title - $creation_date_youtube${trim_label}")
            fi
            "$SCRIPT_DIR"/youtubeuploader "${UPLOAD_ARGS_TRIMMED[@]}"
            log "Trimmed upload finished for VOD $video_id"
        fi
    fi

    # ── Archive to final destination ───────────────────────────────────────────
    if [ "$PRETEND_MODE" = true ]; then
        log "Pretend mode: would archive VOD $video_id to $OUTPUT_PATH/$CHANNEL/${creation_date}_${video_id}/"
    else
        log "Moving VOD $video_id to archive directory"
        archive_dir="$OUTPUT_PATH/$CHANNEL/${creation_date}_${video_id}"
        mkdir -p "$archive_dir"
        rm -f "$vod_tmpdir/video_trimmed."* "$vod_tmpdir/resolved_meta.json"
        echo "$data" > "$vod_tmpdir/metadata.json"
        mv -v "$vod_tmpdir/"* "$archive_dir/"
    fi

    # ── Mark as archived ───────────────────────────────────────────────────────
    jq --arg id "$video_id" '. += [$id]' "$archived_video_ids_file" > "$archived_video_ids_file.tmp" && mv "$archived_video_ids_file.tmp" "$archived_video_ids_file"
    log "VOD $video_id marked as archived"
done

log "Pipeline completed — processed $new_count VOD(s)"