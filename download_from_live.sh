# Stop si erreur pas handled, erreur si var non def
# pipefail arrête le script si cmd1 dans cmd1 | jq cause une erreur, évitant des comportement indet 
set -euo pipefail

cleanup() {
	rm -rf "$tmpdir"
}
SCRIPT_NAME=$(basename "$0")
source "$(dirname "$0")/log.sh"

channel="${1:-}"
output_path="${2:-}"
tmpdir="${3:-}"
if [ -z "$channel" ] || [ -z "$output_path" ] || [ -z "$tmpdir" ]; then
	echo "Usage: $0 <channel_name> <output_path> <tmpdir>"
	exit 1
fi

channel_info_file="id_$channel"
if [ ! -f "$channel_info_file" ] ; then
	log "Getting id of channel $channel"
	# Getting id of channel (necessary for videos api call)
	raw_data=$(./twitch api get /users -q login=$channel)
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
current_download_file="downloading_$user_id"

log "Checking if $channel is live : "
# If currently live -> download
[ $(./twitch api get /streams -q user_id=$user_id | jq 'isempty(.data[])') = true ] && log "Not currently streaming" && exit 1
log "Currently streaming"
[ ! -f "$current_download_file" ] && log "And already downloading" && exit 1
log "Starting download of current stream from the beginning"

# Getting channel's last stream data
raw_data=$(./twitch api get /videos -q type=archive -q first=1 -q user_id=$user_id)
if echo "$raw_data" | jq -e 'isempty(.data[])' >/dev/null ; then
	log "Error fetching last stream's data"
	exit 1
fi 
data=$(echo $raw_data | jq '.data[]')
video_id=$(echo $data | jq '.id | tonumber')
title=$(echo $data | jq -r '.title')
creation_date=$(echo $data | jq -r '.created_at | split("T")[0]')

log "Title=$title"
log "Date=$creation_date"
log "ID=$video_id"

[ ! -f "$channel"_last_video_id ] && echo 0 > "$channel"_last_video_id && log "Not any last video was detected"
[ $(cat "$channel"_last_video_id) = $video_id ] && log "Last video detected is the same as last downloaded" && exit 1


# output_path="$output_path/$channel"
# archive_dir="$output_path/$creation_date""_$video_id"
# mkdir -p "$archive_dir"

# filename is actually path + filename
filename=$(~/.local/bin/yt-dlp https://twitch.tv/videos/$video_id --print filename --progress-delta 15 --newline -o "$tmpdir/video.%(ext)s")
ext="${filename##*.}"
echo "$channel" > "$current_download_file"
~/.local/bin/yt-dlp https://twitch.tv/videos/$video_id --live-from-start --progress-delta 15 --no-part --newline --verbose -o "$tmpdir/video.%(ext)s" 
echo "$video_id" > last_video_id 
# echo "$data" > "$archive_dir/metadata.json"
echo "$data" > "$tmpdir/metadata.json"
# mv "$filename" "$archive_dir/video.$ext" -v
# rm -f "$current_download_file"

log "All data in $tmpdir"

trap cleanup EXIT