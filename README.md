# TTS plugin for koreader

Adds text to speech capabilities using [piper](https://github.com/OHF-Voice/piper1-gpl/) as a backend

## Installation

1. Install [piper](https://github.com/OHF-Voice/piper1-gpl/) on any device within your network using `pip install piper-tts>=1.3.0`  
   I tried getting piper to work on my kindle, but did not succed, so I instead run it on my computer and connect to it via my local WiFi.
   It could in theory run on a phone in Termux, but the package is broken there right now
2. Download a piper voice and try it out [with this guide](https://github.com/OHF-Voice/piper1-gpl/blob/main/docs/API_HTTP.md)
3. Set up the piper web server [with this guide](https://github.com/OHF-Voice/piper1-gpl/blob/main/docs/API_HTTP.md)
4. Download this repo
5. Change the `play` file to be able to play audio files on your target device.
   The default one uses the [sox KUAL app from mobileread](https://www.mobileread.com/forums/showthread.php?t=336390), so install it if you're on Kindle
6. Change the `stop_playing` file be able to interrupt playback. Again, the default file is made for sox on kindle
7. Drop the entire TTS.koplugin directory into koreader/plugins on your device
8. Run the piper web server from before and remember the IP and port it gives you
9. Open koreader, open a book, click on "Start TTS mode" in the typesetting menu, click on the settings icon,
   click on "TTS server URL" and input the ip you remembered
10. You're done!

## Scripts
the `play` is invoked with the file name to play as the first argument and the volume as the second argument.
The plugin thinks the playback is finished when the script outputs any charachter,
so make sure to `>/dev/null 2>/dev/null` anything that can output text and add an `echo` at the end

the `stop_playing` is run to interrupt playback, so it should kill the program you used in the `play` script

the `on_tts_start` script is run when you click the "Start TTS mode" button in koreader.
You can put stuff like connecting to bluetooth headphones there
