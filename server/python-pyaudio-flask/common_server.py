"""
Flask web server with HTTP API for TTS.koplugin
is originally based on https://github.com/OHF-Voice/piper1-gpl/blob/47e370fe1feba5c34bb59dc6f73c3e0cde9a3746/src/piper/http_server.py
"""

import bisect
import json
import logging
import os
import wave
from collections import deque
from io import BytesIO
from typing import Any, AsyncGenerator, Awaitable, Callable

import pyaudio
from flask import Flask, request

_LOGGER = logging.getLogger()

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
    buffer: BytesIO
    remaining_frames: None | int
    framerate: None | int
    playobj = None

    def __init__(self, wav: BytesIO):
        self.buffer = wav

    def play(self, p: pyaudio.PyAudio):
        if self.started():
            self.stop()
        self.buffer.seek(0)
        wav = wave.open(self.buffer)
        self.remaining_frames = wav.getnframes()
        self.framerate = wav.getframerate()

        def callback(_in_data, frame_count, _time_info, _status):
            self.remaining_frames -= frame_count
            return (wav.readframes(frame_count), pyaudio.paContinue)

        self.playobj = p.open(
            format=p.get_format_from_width(wav.getsampwidth()),
            channels=wav.getnchannels(),
            rate=wav.getframerate(),
            output=True,
            stream_callback=callback,
        )

    def started(self):
        return self.playobj is not None

    def remaining(self):
        if self.remaining_frames is not None and self.framerate is not None:
            rem = self.remaining_frames / self.framerate
            if rem < 0:
                self.remaining_frames = 0
                return 0.0
            return rem
        return float("inf")

    def stop(self):
        self.remaining_frames = 0
        if self.started():
            self.playobj.stop_stream()
            self.playobj.close()
        self.playobj = None


def create_server(
    voices: Callable[[], AsyncGenerator[tuple[str, str]]],
    inference: Callable[[str, Any, Any, Any, BytesIO], Awaitable[None]],
) -> Flask:
    # pyaudio init is too noisy, so I point it to devnull
    stderr = os.dup(2)
    null = os.open(os.devnull, os.O_RDWR)
    os.dup2(null, 2)
    audio = pyaudio.PyAudio()
    os.dup2(stderr, 2)
    os.close(null)

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
        cache.play(audio)
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
