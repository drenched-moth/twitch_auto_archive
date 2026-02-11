import subprocess
import shutil
import sys
from datetime import date
import os
import getopt
from selenium import webdriver
from selenium.webdriver.support.ui import WebDriverWait
from selenium.webdriver.support import expected_conditions as EC  
from selenium.webdriver.common.by import By
#from selenium.webdriver.firefox.service import Service as FirefoxService

DEFAULT_OUTPUT_DIR = "./"
FORMAT = "mkv"
output_dir = DEFAULT_OUTPUT_DIR
channel_name = None

# Parsing command line arguments
options, arguments = getopt.getopt(os.sys.argv[1:], "c:o:", ["channel=", "output="])
for option, argument in options:
    if option in ("-c", "--channel"):
        channel_name = argument
    if option in ("-o", "--output"):
        output_dir = argument

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
WebDriverWait(driver, 10).until(
    EC.presence_of_element_located((By.TAG_NAME, "article"))
)


## Avant de démarrer le download on veut vérifier que le live est terminé
## pour cela on peut sauvegarder la longueur de la vidéo et vérifier qu'elle n'a pas changé après quelques secondes (à voir s'il faut faire un sleep ou pas)

video_length1 = driver.find_elements(By.TAG_NAME, "article")[0].find_element(By.CLASS_NAME, "ScMediaCardStatWrapper-sc-anph5i-0").text
print(f"Length of last video detected as: {video_length1}")

driver.get(driver.current_url)
WebDriverWait(driver, 10).until(
    EC.presence_of_element_located((By.TAG_NAME, "article"))
)

video_length2 = driver.find_elements(By.TAG_NAME, "article")[0].find_element(By.CLASS_NAME, "ScMediaCardStatWrapper-sc-anph5i-0").text
print(f"Length of last video detected as: {video_length2}")

links_to_videos = driver.find_elements(By.TAG_NAME, "article")
partial_link = links_to_videos[0].find_element(By.TAG_NAME, "a").get_attribute("href")
curr_url = partial_link

print(f"Partial url detected as last video of user \"{channel_name}\": {curr_url}")
links_to_videos = driver.find_elements(By.TAG_NAME, "article")

#partial_link = links_to_videos[0].find_element(By.TAG_NAME, "a").get_attribute("href")
#curr_url = partial_link

#curr_url = driver.current_url
#print(f"Partial url detected as last video of user \"{channel_name}\": {curr_url}")

driver.quit()
if video_length1 != video_length2:
    print("Live stream is still ongoing. Will not attempt to download.")
    sys.exit(0)


curr_url_essential = curr_url.split("?")[0]
video_id = curr_url_essential.split("/")[-1]

print("ID of last video as detected:")
print(video_id)

last_video_id_path = "./last_video_id"

try:
    with open(last_video_id_path, "r") as f:
        last_video_id = f.readline().strip()
        print("ID of last video downloaded:")
        print(last_video_id)
except FileNotFoundError:
    print("No record of last video ID found. Assuming this is the first run.")
    last_video_id = None

#full_path = os.path.join(output_dir, str(date.today()))
filename = f"{date.today()}.{FORMAT}"
full_path = os.path.join(output_dir, filename)
print(f"Temporary filename for downloaded video: {filename}")
print(f"Full path for output file after finished download: {full_path}")
command = ["pipenv", "run", "yt-dlp", curr_url_essential, "-o", str(date.today()), "-t", FORMAT]
flag_run = False

if last_video_id != video_id:
    try:
        subprocess.run(command, check=True, text=True)
        flag_run = True
    except subprocess.CalledProcessError as e:
        print("Download failed. Will not update last video ID.")
        print(f"Error downloading video: {e}", file=sys.stderr)
        print(f"STDOUT: {e.stdout}", file=sys.stdout)
        print(f"STDERR: {e.stderr}", file=sys.stderr)

if flag_run:
    with open(last_video_id_path, "w") as f:
        f.write(video_id)
    shutil.move(f"./{filename}", full_path)