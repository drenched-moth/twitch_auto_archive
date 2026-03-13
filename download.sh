# Stop si erreur pas handled, erreur si var non def
# pipefail arrête le script si cmd1 dans cmd1 | jq cause une erreur, évitant des comportement indet 
set -euo pipefail

SCRIPT_NAME=$(basename "$0")
source "$(dirname "$0")/log.sh"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

LIVE_FROM_START=false
 
usage() {
    echo "Usage: $0 [-l] <channel_name> <output_path> <tmpdir>"
    echo "  -l    Require live stream and download from the beginning."
    echo "        Falls back to regular download if --live-from-start is unsupported."
    exit 1
}
 
while getopts ":l" opt; do
    case $opt in
        l) LIVE_FROM_START=true ;;
        *) usage ;;
    esac
done
shift $((OPTIND - 1))

channel="${1:-}"
output_path="${2:-}"
tmpdir="${3:-}"
if [ -z "$channel" ] || [ -z "$output_path" ] || [ -z "$tmpdir" ]; then
	echo "Usage: $0 <channel_name> <output_path> <tmpdir>"
	exit 1
fi

files_dir="$SCRIPT_DIR/script_files"
channel_dir="$files_dir/$channel"
mkdir -p "$channel_dir"

channel_info_file="$channel_dir/id.json"
if [ ! -f "$channel_info_file" ] ; then
	log "Getting id of channel $channel"
	# Getting id of channel (necessary for videos api call)
	raw_data=$("$SCRIPT_DIR"/twitch api get /users -q login=$channel)
	if echo "$raw_data" | jq -e 'isempty(.data[])' >/dev/null ; then
		log "Error fetching user's id" 
		exit 1
	fi
	echo "$raw_data" > "$channel_info_file"
else
	log "Using cached info for channel $channel"
	raw_data=$(cat "$channel_info_file")
fi

user_id=$(echo "$raw_data" | jq '.data[].id | tonumber')
current_download_file="$channel_dir/downloading_$user_id"

is_live=$("$SCRIPT_DIR"/twitch api get /streams -q user_id=$user_id | jq 'isempty(.data[]) | not')

if [ "$LIVE_FROM_START" = true ]; then
    # In live mode: channel must be streaming
    [ "$is_live" = false ] && log "Not currently streaming" && exit 1
    log "Currently streaming"
    [ -f "$current_download_file" ] && log "Already downloading" && exit 1
    log "Starting download of current stream from the beginning"
else
    # In last-video mode: skip if currently live (will be archived later)
    [ "$is_live" = true ] && log "Currently streaming" && exit 1
    log "Not currently streaming"
fi

# Getting channel's last stream data
raw_data=$("$SCRIPT_DIR"/twitch api get /videos -q type=archive -q first=1 -q user_id=$user_id)
if echo "$raw_data" | jq -e 'isempty(.data[])' >/dev/null ; then
	log "Error fetching last stream's data"
	exit 1
fi 
data=$(echo $raw_data | jq '.data[]')
video_id=$(echo $data | jq '.id | tonumber')
title=$(echo $data | jq -r '.title')
creation_date=$(echo $data | jq -r '.created_at | split("T")[0]')

log "Title=$title, Date=$creation_date, ID=$video_id"

last_video_id_file="$channel_dir/last_video_id"
[ ! -f "$last_video_id_file" ] && echo 0 > "$last_video_id_file" && log "No previous video detected"
[ $(cat "$last_video_id_file") = $video_id ] && log "Last video is the same as last downloaded" && exit 1

touch "$current_download_file"

if [ "$LIVE_FROM_START" = true ]; then
    log "Attempting download with --live-from-start"
    if ~/.local/bin/yt-dlp https://twitch.tv/videos/$video_id \
            --live-from-start --progress-delta 15 --no-part --newline \
            -o "$tmpdir/video.%(ext)s" ; then
        log "--live-from-start succeeded"
    else
        log "--live-from-start failed (unsupported or error), falling back to regular download"
		exit 1
        # ~/.local/bin/yt-dlp https://twitch.tv/videos/$video_id \
        #     -N 4 --progress-delta 15 --no-part --newline \
        #     -o "$tmpdir/video.%(ext)s"
    fi
else
    ~/.local/bin/yt-dlp https://twitch.tv/videos/$video_id \
        -N 4 --progress-delta 15 --no-part --newline \
        -o "$tmpdir/video.%(ext)s"
fi
 
echo "$video_id" > "$last_video_id_file"
echo "$data" > "$tmpdir/metadata.json"
 
rm -f "$current_download_file"

log "All data in $tmpdir"