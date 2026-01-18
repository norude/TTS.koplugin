#!/usr/bin/env python3.13
import argparse
import logging
from io import BytesIO

import edge_tts
import pydub
from common_server import create_server
from edge_tts.constants import DEFAULT_VOICE

_LOGGER = logging.getLogger()


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--host", default="0.0.0.0", help="HTTP server host")
    parser.add_argument("--port", type=int, default=5000, help="HTTP server port")
    parser.add_argument(
        "--length-scale", "--length_scale", type=float, help="Phoneme length"
    )
    parser.add_argument("--volume", type=float, help="Volume")
    parser.add_argument(
        "--debug", action="store_true", help="Print DEBUG messages to console"
    )
    args = parser.parse_args()
    logging.basicConfig(level=logging.DEBUG if args.debug else logging.INFO)
    _LOGGER.debug(args)

    async def voices() -> set[str]:
        voices = await edge_tts.list_voices()
        return {voice["ShortName"] for voice in voices}

    async def inference(text: str, voice, length_scale, volume, wav_io: BytesIO):
        voice = str(voice if voice is not None else DEFAULT_VOICE)
        length_scale = float(
            length_scale
            if length_scale is not None
            else args.length_scale
            if args.length_scale is not None
            else 1
        )

        volume = float(
            volume
            if volume is not None
            else args.volume
            if args.volume is not None
            else 1
        )

        communicate = edge_tts.Communicate(
            text,
            voice,
            rate=f"{100 * (1 / length_scale - 1):+.0f}%",
            volume=f"{125 * (volume - 0.8):+.0f}%",
        )
        compressed_file = BytesIO()
        async for chunk in communicate.stream():
            if chunk["type"] == "audio":
                assert "data" in chunk
                compressed_file.write(chunk["data"])
        compressed_file.seek(0)
        segment: pydub.AudioSegment = pydub.AudioSegment.from_file(compressed_file)
        segment.export(wav_io, "wav")

    app = create_server(voices, inference)
    app.run(host=args.host, port=args.port)


if __name__ == "__main__":
    main()
