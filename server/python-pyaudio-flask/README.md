# The python-pyaudio server
It uses pyaudio to play audio and one of 
1. [piper-tts](https://github.com/OHF-Voice/piper1-gpl)
2. [edge-tts](https://github.com/rany2/edge-tts) 

for inference

## Instalation
1. `pip install flask[async] pyaudio` (It also requires portaudio be installed in your package manager)
2. Select either [piper-tts](#piper-tts) or [edge-tts](#edge-tts)

### piper-tts
1. `pip install piper-tts` (It's kinda hard rn on Termux)
2. Download a piper voice and try it out [with this guide](https://github.com/OHF-Voice/piper1-gpl/blob/main/docs/CLI.md)
3. Run piper-tts.py and remember the ip it says

### edge-tts
1. `pip install edge-tts pydub` (It also requires ffmpeg be installed in your package manager)
2. Run edge-tts.py and remember the ip it says

