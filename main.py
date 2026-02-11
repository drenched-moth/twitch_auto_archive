import subprocess
import yt_dlp
import shutil
import sys
from datetime import date, datetime
import os
import getopt
from selenium import webdriver
from selenium.webdriver.support.ui import WebDriverWait
from selenium.webdriver.support import expected_conditions as EC  
from selenium.webdriver.common.by import By
#from selenium.webdriver.firefox.service import Service as FirefoxService

DEFAULT_OUTPUT_DIR = "./"
FORMAT = "mp4"
format = FORMAT
output_dir = DEFAULT_OUTPUT_DIR
channel_name = None

# Parsing command line arguments
options, arguments = getopt.getopt(os.sys.argv[1:], "c:o:f:", ["channel=", "output=", "format="])
for option, argument in options:
    if option in ("-c", "--channel"):
        channel_name = argument
    if option in ("-o", "--output"):
        output_dir = argument
    if option in ("-f", "--format"):
        format = argument

if not channel_name:
    print("Error: Twitch channel name is required. Use -c or --channel to specify it.", file=sys.stderr)
    sys.exit(1)
if output_dir == DEFAULT_OUTPUT_DIR and not os.path.isdir(output_dir):
    print(f"Error: Output directory '{output_dir}' does not exist.", file=sys.stderr)
    sys.exit(1)

options = webdriver.FirefoxOptions()
options.add_argument("-headless")
driver = webdriver.Firefox(options=options)

driver.get(f"https://www.twitch.tv/{channel_name}/videos?filter=archives&sort=time")
WebDriverWait(driver, 15).until(
    EC.presence_of_element_located((By.TAG_NAME, "article"))
)
WebDriverWait(driver, 15).until(
    EC.presence_of_element_located((By.CLASS_NAME, "ScMediaCardStatWrapper-sc-anph5i-0"))
)

links_to_videos = driver.find_elements(By.TAG_NAME, "article")
partial_link = links_to_videos[0].find_element(By.TAG_NAME, "a").get_attribute("href")
curr_url = partial_link

print(f"Partial url detected as last video of user \"{channel_name}\": {curr_url}")
links_to_videos = driver.find_elements(By.TAG_NAME, "article")

curr_url_essential = curr_url.split("?")[0]
video_id = curr_url_essential.split("/")[-1]

print(f"ID of last video as detected: {video_id}")

last_video_id_path = "./last_video_id"

try:
    with open(last_video_id_path, "r") as f:
        last_video_id = f.readline().strip()
        print(f"ID of last video downloaded: {last_video_id}")
except FileNotFoundError:
    print("No record of last video ID found. Assuming this is the first run.")
    last_video_id = None

if last_video_id == video_id:
    print("Last video ID matches the most recent video. No new video to download.")
    driver.quit()
    sys.exit(0)

## Avant de démarrer le download on veut vérifier que le live est terminé
## pour cela on peut sauvegarder la longueur de la vidéo et vérifier qu'elle n'a pas changé après quelques secondes (à voir s'il faut faire un sleep ou pas)


video_length1 = driver.find_elements(By.TAG_NAME, "article")[0].find_element(By.CLASS_NAME, "ScMediaCardStatWrapper-sc-anph5i-0").text
print(f"Length of last video detected as: {video_length1}")

driver.get(driver.current_url)

WebDriverWait(driver, 15).until(
    EC.presence_of_element_located((By.TAG_NAME, "article"))
)
WebDriverWait(driver, 15).until(
    EC.presence_of_element_located((By.CLASS_NAME, "ScMediaCardStatWrapper-sc-anph5i-0"))
)
WebDriverWait(driver, 15).until(
    EC.presence_of_element_located((By.TAG_NAME, "h4"))
)

article = driver.find_elements(By.TAG_NAME, "article")[0]
stream_title = article.find_element(By.TAG_NAME, "h4").text
print(f"Title of last video detected as: {stream_title}")


links_to_videos = driver.find_elements(By.TAG_NAME, "article")
video_length2 = links_to_videos[0].find_element(By.CLASS_NAME, "ScMediaCardStatWrapper-sc-anph5i-0").text
print(f"Length of last video detected as: {video_length2}")

stream_date = links_to_videos[0].find_elements(By.TAG_NAME, "img")[-1].get_attribute("title")
stream_date_obj = datetime.strptime(stream_date, "%b %d, %Y").date()
print(f"Found date of last video: {stream_date} -> {stream_date_obj}")

driver.quit()
if video_length1 != video_length2:
    print("Live stream is still ongoing. Will not attempt to download.")
    sys.exit(0)

tmp_filename = os.path.join(DEFAULT_OUTPUT_DIR, f"{stream_date_obj}.{format}")
# below should already be printed by yt-dlp
#print(f"Temporary filename for downloaded video: {tmp_filename}")

ydl_opts = {
    'outtmpl': {'default': tmp_filename},
    'concurrent_fragment_downloads': 2,           
    'progress_delta': 10.0,
    'progress_with_newline': True
}
flag_run = False

if last_video_id != video_id:
    try:
        with yt_dlp.YoutubeDL(ydl_opts) as ydl:
            info_dict = ydl.extract_info(curr_url)
            video_title = info_dict['title']
        flag_run = True
    except Exception as e:
        print("Download failed. Will not update last video ID.")
        print(f"Error downloading video: {e}", file=sys.stderr)

#stream_title = video_title
filename = f"{stream_date_obj} - {stream_title}.{format}"
full_path = os.path.join(output_dir, filename)
print(f"Full path for output file after finished download: {full_path}")

if flag_run:
    with open(last_video_id_path, "w") as f:
        f.write(video_id)
    shutil.move(tmp_filename, full_path)