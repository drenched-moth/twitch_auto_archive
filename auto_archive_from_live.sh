# Stop si erreur pas handled, erreur si var non def
# pipefail arrête le script si cmd1 dans cmd1 | jq cause une erreur, évitant des comportement indet 
set -euo pipefail

cleanup() {
	rm -rf "$tmpdir"
}

channel="${1:-}"
output_path="${2:-}"
if [ -z "$channel" ] || [ -z "$output_path" ]; then
	echo "Usage: $0 <channel_name> <output_path>"
	exit 1
fi

channel_info_file="id_$channel"
if [ ! -f "$channel_info_file" ] ; then
	echo "Getting id of channel $channel"
	# Getting id of channel (necessary for videos api call)
	raw_data=$(./twitch api get /users -q login=$channel)
	if echo "$raw_data" | jq -e 'isempty(.data[])' >/dev/null ; then
		echo "Error fetching user's id" 
		exit 1
	fi
	echo "$raw_data" > "$channel_info_file"
else
	raw_data=$(cat "$channel_info_file")
fi

user_id=$(echo "$raw_data" | jq '.data[].id | tonumber')
current_download_file="downloading_$user_id"

echo -n "Checking if $channel is live : "
# If currently live -> download
[ $(./twitch api get /streams -q user_id=$user_id | jq 'isempty(.data[])') = true ] && echo "Not currently streaming" && exit 1
echo -n "Currently streaming"
[ ! -f "$current_download_file" ] && echo " and already downloading" && exit 1
echo " starting download of current stream from the beginning"

# Getting channel's last stream data
raw_data=$(./twitch api get /videos -q type=archive -q first=1 -q user_id=$user_id)
if echo "$raw_data" | jq -e 'isempty(.data[])' >/dev/null ; then
	echo "Error fetching last stream's data"
	exit 1
fi 
data=$(echo $raw_data | jq '.data[]')
video_id=$(echo $data | jq '.id | tonumber')
title=$(echo $data | jq -r '.title')
creation_date=$(echo $data | jq -r '.created_at | split("T")[0]')

echo "Title=$title"
echo "Date=$creation_date"
echo "ID=$video_id"

[ ! -f last_video_id ] && echo 0 > last_video_id && echo "Not any last video was detected"
[ $(cat last_video_id) = $video_id ] && echo "Last video detected is the same as last downloaded" && exit 1

# Setup before downloading new video
tmpdir=$(mktemp -d -t twitch-archive-XXXXXX)

output_path="$output_path/$channel"
archive_dir="$output_path/$creation_date""_$video_id"
mkdir -p "$archive_dir"

# filename is actually path + filename
filename=$(~/.local/bin/yt-dlp https://twitch.tv/videos/$video_id --print filename --progress-delta 15 --newline -o "$tmpdir/video.%(ext)s")
ext="${filename##*.}"
echo "$channel" > "$current_download_file"
~/.local/bin/yt-dlp https://twitch.tv/videos/$video_id --live-from-start --progress-delta 15 --no-part --newline --verbose -o "$tmpdir/video.%(ext)s" 
echo "$video_id" > last_video_id 
echo "$data" > "$archive_dir/metadata.json"
mv "$filename" "$archive_dir/video.$ext" -v
rm -f "$current_download_file"

echo "Stream archived in $archive_dir"

trap cleanup EXIT
