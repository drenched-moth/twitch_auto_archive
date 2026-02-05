import subprocess
import sys
from selenium import webdriver
from selenium.webdriver.support.ui import WebDriverWait
from selenium.webdriver.support import expected_conditions as EC  
from selenium.webdriver.common.by import By

channel_name = "eteicos_"

options = webdriver.FirefoxOptions()
options.add_argument("-headless")
driver = webdriver.Firefox(options=options)

driver.get(f"https://www.twitch.tv/{channel_name}/videos?filter=archives&sort=time")
#print(driver.current_url)
WebDriverWait(driver, 10).until(
    EC.presence_of_element_located((By.TAG_NAME, "article"))
)

links_to_videos = driver.find_elements(By.TAG_NAME, "article")
links_to_videos[0].click()
curr_url = driver.current_url
print(f"Full url detected as last video of user \"{channel_name}\":")
print(curr_url)
driver.quit()

curr_url_essential = curr_url.split("?")[0]
video_id = curr_url_essential.split("/")[-1]

#print(curr_url_essential)
print(f"ID of last video as detected:")
print(video_id)

last_video_id_path = "./last_video_id"

with open(last_video_id_path, "r") as f:
    last_video_id = f.readline().strip()
    print(f"ID of last video downloaded:")
    print(last_video_id)

command = ["yt-dlp", curr_url_essential]
flag_run = False

if last_video_id != video_id:
    try:
        subprocess.run(command, check=True, capture_output=True, text=True)
        flag_run = True
    except subprocess.CalledProcessError as e:
        print(f"Error downloading video: {e}")
        print(f"STDOUT: {e.stdout}", file=sys.stdout)
        print(f"STDERR: {e.stderr}", file=sys.stderr)

if flag_run:
    with open(last_video_id_path, "w") as f:
        f.write(video_id)
    