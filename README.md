# Twitch auto archival tool
## Why this project ?
This is a fairly simple script which allows to simplify a homemade auto_archival of twitch VODs.

## How to use it
The main idea is to use this script to keep an archive of a channel's VOD. This script should be deployed on a server, and run regularly with chron or any setup which does the same thing.
The twitch-cli, yt-dlp and youtubedownloader binaries locations are assumed, locations in the script might need to be changed to work properly.

Youtubedownloader has to be properly set up to work in this project. It is not in the scope of this project to configure youtubedownloader through the script. Same goes for twitch-cli. The script as of yet has only been tested on channels with free VODs, it should work for channels with subscription locked VODs if twitch-cli has been properly setup with a user token, but this feature has not been tested yet.

The script needs to be called with the twitch channel name, youtube channel name (actually this is only a trick to use the right local file, secrets and token, no obligation to have the actual YT channel name) and finally the final output location where the archive is located. The distant output location is useful, to have most of the processing happening locally on the server, download, transcoding, upload, before transferring the presumably big file to a slower storage device for archival purposes.
## Dependencies
- ffmpeg
- yt-dlp
- twitch-cli
- youtubedownloader
