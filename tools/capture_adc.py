#!/usr/bin/env python3
"""Capture the ESP32 diagnostic ADC stream and save it as a WAV file."""

from __future__ import annotations

import argparse
import pathlib
import struct
import sys
import time
import wave

import serial


def read_line(port: serial.Serial, deadline: float) -> bytes:
    data = bytearray()
    while time.monotonic() < deadline:
        byte = port.read(1)
        if not byte:
            continue
        data += byte
        if byte == b"\n":
            return bytes(data)
    raise TimeoutError(f"Timed out waiting for line; received {data!r}")


def read_until_prefix(port: serial.Serial, prefix: bytes, timeout: float) -> bytes:
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        line = read_line(port, deadline)
        text = line.decode("utf-8", errors="replace").rstrip()
        if text:
            print(f"board: {text}", flush=True)
        if line.startswith(prefix):
            return line
    raise TimeoutError(f"Timed out waiting for {prefix!r}")


def read_exact(port: serial.Serial, count: int, timeout: float) -> bytes:
    deadline = time.monotonic() + timeout
    data = bytearray()
    while len(data) < count and time.monotonic() < deadline:
        chunk = port.read(count - len(data))
        if chunk:
            data.extend(chunk)
    if len(data) != count:
        raise TimeoutError(f"Expected {count} audio bytes, received {len(data)}")
    return bytes(data)


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--port", default="/dev/cu.usbserial-0001")
    parser.add_argument("--output", type=pathlib.Path)
    parser.add_argument("--countdown", type=float, default=8.0)
    mode = parser.add_mutually_exclusive_group()
    mode.add_argument("--arm-offline", action="store_true")
    mode.add_argument("--download-offline", action="store_true")
    args = parser.parse_args()

    if not args.arm_offline and args.output is None:
        parser.error("--output is required unless --arm-offline is used")
    if args.output is not None:
        args.output.parent.mkdir(parents=True, exist_ok=True)
    with serial.Serial(args.port, 115200, timeout=0.1) as port:
        time.sleep(2.0)
        port.reset_input_buffer()
        if args.arm_offline:
            port.write(b"A")
            port.flush()
            read_until_prefix(port, b"OFFLINE_CAPTURE_ARMED", 5.0)
            print(
                "ARMED: disconnect USB, power the board from the battery, "
                "and wait at least 10 seconds",
                flush=True,
            )
            return 0

        if args.download_offline:
            port.write(b"D")
            port.flush()
            begin = read_until_prefix(port, b"CAPTURE_BEGIN ", 5.0)
            _, rate_raw, channels_raw, frames_raw, byte_count_raw = begin.split()
            sample_rate = int(rate_raw)
            channels = int(channels_raw)
            frames = int(frames_raw)
            byte_count = int(byte_count_raw)
            pcm = read_exact(port, byte_count, 30.0)
            with wave.open(str(args.output), "wb") as wav:
                wav.setnchannels(channels)
                wav.setsampwidth(2)
                wav.setframerate(sample_rate)
                wav.writeframes(pcm)
            print(
                f"SAVED: {args.output} ({frames / sample_rate:.1f} seconds)",
                flush=True,
            )
            return 0

        print(
            f"READY: recording begins in {args.countdown:g} seconds; "
            "speak continuously until RECORDING COMPLETE appears",
            flush=True,
        )
        time.sleep(args.countdown)
        port.write(b"R")
        port.flush()
        print("RECORDING NOW — SPEAK", flush=True)
        armed = read_until_prefix(port, b"CAPTURE_ARMED ", 5.0)
        _, sample_rate_raw, channels_raw, frames_raw = armed.split()
        expected_rate = int(sample_rate_raw)
        expected_channels = int(channels_raw)
        expected_frames = int(frames_raw)

        begin = read_until_prefix(port, b"CAPTURE_BEGIN ", 10.0)
        _, rate_raw, channels_raw, frames_raw, byte_count_raw = begin.split()
        sample_rate = int(rate_raw)
        channels = int(channels_raw)
        frames = int(frames_raw)
        byte_count = int(byte_count_raw)
        if (sample_rate, channels, frames) != (
            expected_rate,
            expected_channels,
            expected_frames,
        ):
            raise RuntimeError("Capture header changed between ARMED and BEGIN")
        if byte_count != frames * channels * 2:
            raise RuntimeError("Capture byte count is inconsistent")

        print("RECORDING COMPLETE — downloading audio", flush=True)
        pcm = read_exact(port, byte_count, 30.0)
        if sys.byteorder != "little":
            samples = struct.unpack(f"<{frames * channels}h", pcm)
            pcm = struct.pack(f"={frames * channels}h", *samples)

        with wave.open(str(args.output), "wb") as wav:
            wav.setnchannels(channels)
            wav.setsampwidth(2)
            wav.setframerate(sample_rate)
            wav.writeframes(pcm)
        print(f"SAVED: {args.output} ({frames / sample_rate:.1f} seconds)", flush=True)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
