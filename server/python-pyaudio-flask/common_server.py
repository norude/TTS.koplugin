"""
Flask web server with HTTP API for TTS.koplugin
is originally based on https://github.com/OHF-Voice/piper1-gpl/blob/47e370fe1feba5c34bb59dc6f73c3e0cde9a3746/src/piper/http_server.py
"""

import bisect
import json
import logging
import os
import sys
import wave
from collections import deque
from io import BytesIO
from typing import Any, Callable
from collections.abc import Awaitable, AsyncGenerator

import pyaudio
from flask import Flask, request

_LOGGER = logging.getLogger()

_null_fno = os.open(os.devnull, os.O_RDWR)
_stderr_fno = sys.stderr.fileno()
_duplicated_stderr_fno = os.dup(_stderr_fno)


def get_pyaudio():
    # not getting a new pyaudio every playback causes issues on Termux
    # this is not a fix, re-initializing pyaudio constantly just sidesteps the bug
    # a real fix would probably need to be implemented in portaudio directly

    # pyaudio init is too noisy so redirect stderr to null during init
    os.dup2(_null_fno, _stderr_fno)
    audio = pyaudio.PyAudio()
    os.dup2(_duplicated_stderr_fno, _stderr_fno)  # and then restore it
    return audio


handle = str
global_wavs_cache: "dict[handle,WavItem]" = {}
handle_queue: deque[handle] = deque()


def get_cache(handle: handle) -> "WavItem|None":
    return global_wavs_cache.get(handle)


def insert_cache(handle: handle, item: "WavItem") -> handle:
    global global_wavs_cache, handle_queue
    global_wavs_cache[handle] = item
    handle_queue.append(handle)
    if len(handle_queue) > 20:
        del global_wavs_cache[handle_queue.popleft()]
    return handle


def generate_wavs_cache_key(*args) -> handle:
    return hex(hash((*args,)))


class WavItem:
    remaining_frames: None | int = None  # None means not started, 0 means finished
    framerate: None | int = None
    playobj = None
    pyaudio = None

    def __init__(self, wav: BytesIO):
        self.buffer = wav

    def play(self):
        self.stop()
        self.pyaudio = get_pyaudio()
        self.buffer.seek(0)
        wav = wave.open(self.buffer)
        self.remaining_frames = wav.getnframes()
        self.framerate = wav.getframerate()

        def callback(_in_data, frame_count, _time_info, _status):
            self.remaining_frames -= frame_count
            return (wav.readframes(frame_count), pyaudio.paContinue)

        self.playobj = self.pyaudio.open(
            format=self.pyaudio.get_format_from_width(wav.getsampwidth()),
            channels=wav.getnchannels(),
            rate=wav.getframerate(),
            output=True,
            stream_callback=callback,
        )

    def started(self):
        return self.remaining_frames is not None

    def remaining(self):
        if self.remaining_frames is None or self.framerate is None:
            return float("inf")
        rem = self.remaining_frames / self.framerate
        if rem > 0:
            return rem
        self.stop()
        return 0.0

    def stop(self):
        self.remaining_frames = 0
        if self.playobj is not None:
            self.playobj.stop_stream()
            self.playobj.close()
        if self.pyaudio is not None:
            self.pyaudio.terminate()
        self.playobj = None
        self.pyaudio = None

    def __del__(self):
        self.stop()


def create_server(
    voices: Callable[[], AsyncGenerator[tuple[str, str], None]],
    inference: Callable[[str, Any, Any, Any, BytesIO], Awaitable[None]],
) -> Flask:

    # Create web server
    app = Flask(__name__)

    @app.get("/voices")
    async def app_voices() -> dict[str, list[str]]:
        nice_voices: dict[str, list[str]] = {}
        async for key, v in voices():
            cluster = nice_voices[key] = nice_voices.get(key, [])
            idx = bisect.bisect_left(cluster, v)
            if idx == len(cluster) or cluster[idx] != v:
                cluster.insert(idx, v)
        return nice_voices

    @app.post("/")
    async def app_synthesize_or_get_hash_key() -> handle:
        """Get audio from text.

        Expects a JSON object with the format:
        {
          "text": "Text to speak.",      (required)
          "voice": "<voice name>",       (optional)
          "length_scale": 1.0,           (optional)
          "volume": 1.0,                 (optional)
        }
        """
        data = json.loads(request.data)
        text = data.get("text", "").strip()
        if not text:
            raise ValueError("No text provided")

        _LOGGER.debug(data)

        voice = data.get("voice")
        length_scale = data.get("length_scale")
        volume = data.get("volume")

        cache_key = generate_wavs_cache_key(
            text,
            voice,
            length_scale,
            volume,
        )
        cache = get_cache(cache_key)
        if cache is not None:
            _LOGGER.debug("Using cached wav: %s", cache_key)
            return cache_key
        wav_io = BytesIO()
        await inference(text, voice, length_scale, volume, wav_io)
        return insert_cache(cache_key, WavItem(wav_io))

    @app.post("/play")
    def app_play() -> str:
        cache = get_cache(json.loads(request.data).get("handle"))
        if cache is None:
            raise ValueError("handle is invalid")
        cache.play()
        return ""

    @app.post("/remaining")
    def app_remaining() -> str:
        cache = get_cache(json.loads(request.data).get("handle"))
        if cache is None:
            raise ValueError("handle is invalid")
        return json.dumps(
            {
                "started": cache.started(),
                "remaining": cache.remaining(),
            }
        )

    @app.post("/stop")
    def app_stop() -> str:
        cache = get_cache(json.loads(request.data).get("handle"))
        if cache is None:
            raise ValueError("handle is invalid")
        cache.stop()
        return ""

    return app
