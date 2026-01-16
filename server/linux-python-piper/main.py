#!/usr/bin/env python3.13
"""
Flask web server with HTTP API for TTS.koplugin
Uses Piper as the backend and
is originally based on https://github.com/OHF-Voice/piper1-gpl/blob/47e370fe1feba5c34bb59dc6f73c3e0cde9a3746/src/piper/http_server.py

"""

import argparse
from collections import deque
import json
import logging
import wave
from io import BytesIO
from pathlib import Path
from typing import Any, Dict, List, Optional
from urllib.request import urlopen

import pyaudio
from flask import Flask, request
from piper import PiperVoice, SynthesisConfig
from piper.download_voices import VOICES_JSON, download_voice

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


def generate_wavs_cache_key(
    text: str,
    model_id: str,
    speaker_id: int | None,
    length_scale: float | None,
    noise_scale: float | None,
    noise_w_scale: float | None,
    normalize_audio: bool,
    volume: float,
) -> handle:
    return hex(
        hash(
            (
                text,
                model_id,
                speaker_id,
                length_scale,
                noise_scale,
                noise_w_scale,
                normalize_audio,
                volume,
            )
        )
    )


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


def main() -> None:
    """Run HTTP server."""
    parser = argparse.ArgumentParser()
    parser.add_argument("--host", default="0.0.0.0", help="HTTP server host")
    parser.add_argument("--port", type=int, default=5000, help="HTTP server port")
    #
    parser.add_argument("-m", "--model", required=True, help="Path to Onnx model file")
    #
    parser.add_argument("-s", "--speaker", type=int, help="Id of speaker (default: 0)")
    parser.add_argument(
        "--length-scale", "--length_scale", type=float, help="Phoneme length"
    )
    parser.add_argument("--volume", type=float, help="Volume")
    parser.add_argument(
        "--noise-scale", "--noise_scale", type=float, help="Generator noise"
    )
    parser.add_argument(
        "--noise-w-scale",
        "--noise_w_scale",
        "--noise-w",
        "--noise_w",
        type=float,
        help="Phoneme width noise",
    )
    #
    parser.add_argument("--cuda", action="store_true", help="Use GPU")
    #
    parser.add_argument(
        "--sentence-silence",
        "--sentence_silence",
        type=float,
        default=0.0,
        help="Seconds of silence after each sentence",
    )
    #
    parser.add_argument(
        "--data-dir",
        "--data_dir",
        action="append",
        default=[str(Path.cwd())],
        help="Data directory to check for downloaded models (default: current directory)",
    )
    parser.add_argument(
        "--download-dir",
        "--download_dir",
        help="Path to download voices (default: first data dir)",
    )
    #
    parser.add_argument(
        "--debug", action="store_true", help="Print DEBUG messages to console"
    )
    args = parser.parse_args()
    logging.basicConfig(level=logging.DEBUG if args.debug else logging.INFO)
    _LOGGER.debug(args)
    audio = pyaudio.PyAudio()

    if not args.download_dir:
        # Download voices to first data directory if not specified
        args.download_dir = args.data_dir[0]

    download_dir = Path(args.download_dir)

    # Download voice if file doesn't exist
    model_path = Path(args.model)
    if not model_path.exists():
        # Look in data directories
        voice_name = args.model
        for data_dir in args.data_dir:
            maybe_model_path = Path(data_dir) / f"{voice_name}.onnx"
            _LOGGER.debug("Checking '%s'", maybe_model_path)
            if maybe_model_path.exists():
                model_path = maybe_model_path
                break

    if not model_path.exists():
        raise ValueError(
            f"Unable to find voice: {model_path} (use piper.download_voices)"
        )

    default_model_id = model_path.name.rstrip(".onnx")

    # Load voice
    default_voice = PiperVoice.load(model_path, use_cuda=args.cuda)
    loaded_voices: Dict[str, PiperVoice] = {default_model_id: default_voice}

    # Create web server
    app = Flask(__name__)

    @app.route("/voices", methods=["GET"])
    def app_voices() -> Dict[str, Any]:
        """List downloaded voices.

        Outputs a JSON object with the format:
        {
          "<voice name>": { <voice config> },
          ...
        }

        for each voice in your data directories.
        """
        voices_dict: Dict[str, Any] = {}
        config_paths: List[Path] = [Path(f"{model_path}.json")]

        for data_dir in args.data_dir:
            for onnx_path in Path(data_dir).glob("*.onnx"):
                config_path = Path(f"{onnx_path}.json")
                if config_path.exists():
                    config_paths.append(config_path)

        for config_path in config_paths:
            model_id = config_path.name.rstrip(".onnx.json")
            if model_id in voices_dict:
                continue

            with open(config_path, "r", encoding="utf-8") as config_file:
                voices_dict[model_id] = json.load(config_file)

        return voices_dict

    @app.route("/all-voices", methods=["GET"])
    def app_all_voices() -> Dict[str, Any]:
        """List all Piper voices.

        Outputs voices.json from the piper-voices repo on HuggingFace.
        See: https://huggingface.co/rhasspy/piper-voices
        """
        with urlopen(VOICES_JSON) as response:
            return json.load(response)

    @app.route("/download", methods=["POST"])
    def app_download() -> str:
        """Download a voice.

        Downloads the .onnx and .onnx.json file from piper-voices repo on HuggingFace.
        See: https://huggingface.co/rhasspy/piper-voices

        Expects a JSON object with the format:
        {
          "voice": "<voice name>",   (required)
          "force_redownload": false  (optional)
        }

        Returns the name of the voice.
        Voice format must be <language>-<name>-<quality> like "en_US-lessac-medium".
        """
        data = json.loads(request.data)
        model_id = data.get("voice")
        if not model_id:
            raise ValueError("voice is required")

        force_redownload = data.get("force_redownload", False)
        download_voice(model_id, download_dir, force_redownload=force_redownload)

        return model_id

    @app.route("/", methods=["POST"])
    def app_synthesize_or_get_hash_key() -> handle:
        """Synthesize audio from text.

        Expects a JSON object with the format:
        {
          "text": "Text to speak.",      (required)
          "voice": "<voice name>",       (optional)
          "speaker": "<speaker name>",   (optional)
          "speaker_id": "<speaker id>",  (optional, overrides speaker)
          "length_scale": 1.0,           (optional)
          "noise_scale": 0.667,          (optional)
          "length_w_scale": 0.8,         (optional)
          "volume": 1.0,                 (optional)
        }
        """
        global global_wavs_cache
        data = json.loads(request.data)
        text = data.get("text", "").strip()
        if not text:
            raise ValueError("No text provided")

        _LOGGER.debug(data)

        model_id = data.get("voice", default_model_id)
        voice = loaded_voices.get(model_id)
        if voice is None:
            for data_dir in args.data_dir:
                maybe_model_path = Path(data_dir) / f"{model_id}.onnx"
                if maybe_model_path.exists():
                    _LOGGER.debug("Loading voice %s", model_id)
                    voice = PiperVoice.load(maybe_model_path, use_cuda=args.cuda)
                    loaded_voices[model_id] = voice
                    break

        if voice is None:
            _LOGGER.warning("Voice not found: %s. Using default voice.", model_id)
            voice = default_voice
            model_id = default_model_id

        speaker_id: Optional[int] = data.get("speaker_id")
        if (voice.config.num_speakers > 1) and (speaker_id is None):
            speaker = data.get("speaker")
            if speaker:
                speaker_id = voice.config.speaker_id_map.get(speaker)

            if speaker_id is None:
                _LOGGER.warning(
                    "Speaker not found: '%s' in %s",
                    speaker,
                    voice.config.speaker_id_map.keys(),
                )
                speaker_id = args.speaker or 0

        if (speaker_id is not None) and (speaker_id > voice.config.num_speakers):
            speaker_id = 0

        syn_config = SynthesisConfig(
            speaker_id=speaker_id,
            length_scale=float(
                data.get(
                    "length_scale",
                    (
                        args.length_scale
                        if args.length_scale is not None
                        else voice.config.length_scale
                    ),
                )
            ),
            noise_scale=float(
                data.get(
                    "noise_scale",
                    (
                        args.noise_scale
                        if args.noise_scale is not None
                        else voice.config.noise_scale
                    ),
                )
            ),
            noise_w_scale=float(
                data.get(
                    "noise_w_scale",
                    (
                        args.noise_w_scale
                        if args.noise_w_scale is not None
                        else voice.config.noise_w_scale
                    ),
                )
            ),
            volume=float(
                data.get(
                    "volume",
                    (args.volume if args.volume is not None else 1.0),
                )
            ),
        )

        cache_key = generate_wavs_cache_key(
            text,
            model_id,
            speaker_id,
            syn_config.length_scale,
            syn_config.noise_scale,
            syn_config.noise_w_scale,
            syn_config.normalize_audio,
            syn_config.volume,
        )

        cache = get_cache(cache_key)
        if cache is not None:
            _LOGGER.debug("Using cached wav: %s", cache_key)
            return cache_key

        _LOGGER.debug("Synthesizing text: '%s' with config=%s", text, syn_config)
        wav_io = BytesIO()
        with wave.open(wav_io, "wb") as wav_file:
            wav_params_set = False
            for i, audio_chunk in enumerate(voice.synthesize(text, syn_config)):
                if not wav_params_set:
                    wav_file.setframerate(audio_chunk.sample_rate)
                    wav_file.setsampwidth(audio_chunk.sample_width)
                    wav_file.setnchannels(audio_chunk.sample_channels)
                    wav_params_set = True

                if i > 0:
                    wav_file.writeframes(
                        bytes(int(voice.config.sample_rate * args.sentence_silence * 2))
                    )

                wav_file.writeframes(audio_chunk.audio_int16_bytes)
        return insert_cache(cache_key, WavItem(wav_io))

    @app.route("/play", methods=["POST"])
    def app_play() -> str:
        data = json.loads(request.data)
        cache_key = data.get("handle")
        cache = get_cache(cache_key)
        if cache is None:
            raise ValueError("handle is invalid")
        cache.play(audio)
        return ""

    @app.route("/remaining", methods=["POST"])
    def app_remaining() -> str:
        data = json.loads(request.data)
        cache_key = data.get("handle")
        cache = get_cache(cache_key)
        if cache is None:
            raise ValueError("handle is invalid")
        return json.dumps(
            {
                "started": cache.started(),
                "remaining": cache.remaining(),
            }
        )

    @app.route("/stop", methods=["POST"])
    def app_stop() -> str:
        data = json.loads(request.data)
        cache_key = data.get("handle")
        cache = get_cache(cache_key)
        if cache is None:
            raise ValueError("handle is invalid")
        cache.stop()
        return ""

    app.run(host=args.host, port=args.port)
    audio.terminate()


if __name__ == "__main__":
    main()
