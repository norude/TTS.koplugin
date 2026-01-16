# TTS plugin for koreader

Adds text to speech capabilities using another device for both inference and playback. Uses [piper](https://github.com/OHF-Voice/piper1-gpl/) as a backend on linux

## Installation

1. Download this repo
2. Select a server from the server/ directory that matches your server's platform. The server will perform inference as well as play the created audio.
3. Drop that directory onto your server device and read its README.md
4. Drop the entire TTS.koplugin directory (except for server/) into koreader/plugins on your reader device
5. Open koreader, open a book, click on "Start TTS mode" in the typesetting menu, click on the settings icon,
   click on "TTS server URL" and input the ip your server spat out
6. You're done!
