#!/usr/bin/env python3
"""Generate and analyse an in-car logarithmic-sweep delay measurement."""

from __future__ import annotations

import argparse
import json
import math
import pathlib
import wave

import numpy as np


SAMPLE_RATE = 44_100
PRE_SILENCE_SECONDS = 1.0
SWEEP_SECONDS = 4.0
POST_SILENCE_SECONDS = 1.0
SWEEP_START_HZ = 35.0
SWEEP_END_HZ = 12_000.0
SWEEP_AMPLITUDE = 0.03


def write_pcm16(path: pathlib.Path, samples: np.ndarray, sample_rate: int) -> None:
    values = np.clip(samples, -1.0, 1.0)
    pcm = np.round(values * 32767.0).astype("<i2")
    path.parent.mkdir(parents=True, exist_ok=True)
    with wave.open(str(path), "wb") as output:
        output.setnchannels(1)
        output.setsampwidth(2)
        output.setframerate(sample_rate)
        output.writeframes(pcm.tobytes())


def read_pcm(path: pathlib.Path) -> tuple[int, np.ndarray]:
    with wave.open(str(path), "rb") as source:
        sample_rate = source.getframerate()
        channels = source.getnchannels()
        width = source.getsampwidth()
        frames = source.getnframes()
        raw = source.readframes(frames)

    if width == 2:
        samples = np.frombuffer(raw, dtype="<i2").astype(np.float64) / 32768.0
    elif width == 3:
        packed = np.frombuffer(raw, dtype=np.uint8).reshape(-1, 3)
        values = (
            packed[:, 0].astype(np.int32)
            | (packed[:, 1].astype(np.int32) << 8)
            | (packed[:, 2].astype(np.int32) << 16)
        )
        values = np.where(values & 0x800000, values | ~0xFFFFFF, values)
        samples = values.astype(np.float64) / 8388608.0
    elif width == 4:
        samples = np.frombuffer(raw, dtype="<i4").astype(np.float64) / 2147483648.0
    else:
        raise ValueError(f"Unsupported {width * 8}-bit PCM in {path}")

    if channels > 1:
        samples = samples.reshape(-1, channels).mean(axis=1)
    return sample_rate, samples


def logarithmic_sweep() -> np.ndarray:
    count = round(SWEEP_SECONDS * SAMPLE_RATE)
    time = np.arange(count, dtype=np.float64) / SAMPLE_RATE
    ratio_log = math.log(SWEEP_END_HZ / SWEEP_START_HZ)
    phase = (
        2.0
        * math.pi
        * SWEEP_START_HZ
        * SWEEP_SECONDS
        / ratio_log
        * (np.exp(time * ratio_log / SWEEP_SECONDS) - 1.0)
    )
    sweep = np.sin(phase)
    fade_count = round(0.03 * SAMPLE_RATE)
    ramp = 0.5 - 0.5 * np.cos(np.linspace(0, math.pi, fade_count))
    sweep[:fade_count] *= ramp
    sweep[-fade_count:] *= ramp[::-1]
    return sweep * SWEEP_AMPLITUDE


def generate(path: pathlib.Path) -> None:
    pre = np.zeros(round(PRE_SILENCE_SECONDS * SAMPLE_RATE))
    post = np.zeros(round(POST_SILENCE_SECONDS * SAMPLE_RATE))
    stimulus = np.concatenate((pre, logarithmic_sweep(), post))
    write_pcm16(path, stimulus, SAMPLE_RATE)
    print(f"Generated {path} ({len(stimulus) / SAMPLE_RATE:.1f} s, {SWEEP_AMPLITUDE:.3f} peak)")


def generate_bursts(path: pathlib.Path, frequency_hz: float, amplitude: float) -> None:
    """Generate three short, repeatable low-frequency Ricker wavelets."""
    duration_seconds = 5.0
    stimulus = np.zeros(round(duration_seconds * SAMPLE_RATE))
    half_width = round(0.06 * SAMPLE_RATE)
    time = np.arange(-half_width, half_width + 1, dtype=np.float64) / SAMPLE_RATE
    position = math.pi * frequency_hz * time
    wavelet = (1.0 - 2.0 * position**2) * np.exp(-(position**2)) * amplitude
    for center_seconds in (1.0, 2.0, 3.0):
        center = round(center_seconds * SAMPLE_RATE)
        stimulus[center - half_width : center + half_width + 1] += wavelet
    write_pcm16(path, stimulus, SAMPLE_RATE)
    print(f"Generated {path} ({duration_seconds:.1f} s, three {frequency_hz:g} Hz wavelets)")


def generate_dual_bursts(path: pathlib.Path) -> None:
    """Generate simultaneous 80 Hz sub and 500 Hz door timing wavelets."""
    duration_seconds = 5.0
    stimulus = np.zeros(round(duration_seconds * SAMPLE_RATE))
    half_width = round(0.08 * SAMPLE_RATE)
    time = np.arange(-half_width, half_width + 1, dtype=np.float64) / SAMPLE_RATE

    def ricker(frequency_hz: float, amplitude: float) -> np.ndarray:
        position = math.pi * frequency_hz * time
        return (1.0 - 2.0 * position**2) * np.exp(-(position**2)) * amplitude

    # The car/sub chain has much more gain at 80 Hz than the door path has at
    # 500 Hz, so use deliberately different source amplitudes. Both remain
    # comfortably below the previously established clipping levels.
    wavelet = ricker(80.0, 0.01) + ricker(500.0, 0.2)
    for center_seconds in (1.0, 2.0, 3.0):
        center = round(center_seconds * SAMPLE_RATE)
        stimulus[center - half_width : center + half_width + 1] += wavelet
    write_pcm16(path, stimulus, SAMPLE_RATE)
    print(f"Generated {path} ({duration_seconds:.1f} s, paired 80/500 Hz wavelets)")


def next_power_of_two(value: int) -> int:
    return 1 << (value - 1).bit_length()


def deconvolve(recording: np.ndarray) -> np.ndarray:
    stimulus = logarithmic_sweep()
    fft_size = next_power_of_two(len(recording) + len(stimulus) - 1)
    stimulus_fft = np.fft.rfft(stimulus, fft_size)
    recording_fft = np.fft.rfft(recording, fft_size)
    power = np.abs(stimulus_fft) ** 2
    regularization = power.max() * 1e-7
    transfer = recording_fft * np.conj(stimulus_fft) / (power + regularization)
    return np.fft.irfft(transfer, fft_size)[: len(recording)]


def bandpass(signal: np.ndarray, low_hz: float, high_hz: float) -> np.ndarray:
    spectrum = np.fft.rfft(signal)
    frequencies = np.fft.rfftfreq(len(signal), 1.0 / SAMPLE_RATE)
    transition = max(5.0, min(100.0, (high_hz - low_hz) * 0.1))
    weights = np.zeros_like(frequencies)
    passband = (frequencies >= low_hz) & (frequencies <= high_hz)
    weights[passband] = 1.0
    lower = (frequencies >= max(0.0, low_hz - transition)) & (frequencies < low_hz)
    if np.any(lower):
        position = (frequencies[lower] - (low_hz - transition)) / transition
        weights[lower] = 0.5 - 0.5 * np.cos(math.pi * position)
    upper = (frequencies > high_hz) & (frequencies <= high_hz + transition)
    if np.any(upper):
        position = (frequencies[upper] - high_hz) / transition
        weights[upper] = 0.5 + 0.5 * np.cos(math.pi * position)
    return np.fft.irfft(spectrum * weights, len(signal))


def envelope(signal: np.ndarray) -> np.ndarray:
    spectrum = np.fft.fft(signal)
    weights = np.zeros(len(signal))
    weights[0] = 1.0
    if len(signal) % 2 == 0:
        weights[1 : len(signal) // 2] = 2.0
        weights[len(signal) // 2] = 1.0
    else:
        weights[1 : (len(signal) + 1) // 2] = 2.0
    return np.abs(np.fft.ifft(spectrum * weights))


def shift_integer(signal: np.ndarray, samples: int) -> np.ndarray:
    shifted = np.zeros_like(signal)
    if samples > 0:
        shifted[samples:] = signal[:-samples]
    elif samples < 0:
        shifted[:samples] = signal[-samples:]
    else:
        shifted[:] = signal
    return shifted


def peak_index(signal: np.ndarray, start_seconds: float, end_seconds: float) -> int:
    start = max(0, round(start_seconds * SAMPLE_RATE))
    end = min(len(signal), round(end_seconds * SAMPLE_RATE))
    return start + int(np.argmax(signal[start:end]))


def analyse(reference_path: pathlib.Path, combined_path: pathlib.Path) -> dict[str, float]:
    reference_rate, reference_recording = read_pcm(reference_path)
    combined_rate, combined_recording = read_pcm(combined_path)
    if reference_rate != SAMPLE_RATE or combined_rate != SAMPLE_RATE:
        raise ValueError("Recordings must be 44.1 kHz")

    # AVFoundation may stop a nominally equal-duration capture a partial audio
    # buffer early. Equalise only the trailing length so sample timing and every
    # recorded value remain untouched.
    recording_length = max(len(reference_recording), len(combined_recording))
    reference_recording = np.pad(
        reference_recording, (0, recording_length - len(reference_recording))
    )
    combined_recording = np.pad(
        combined_recording, (0, recording_length - len(combined_recording))
    )

    reference_ir = deconvolve(reference_recording)
    combined_ir = deconvolve(combined_recording)
    reference_high = bandpass(reference_ir, 2_000.0, 10_000.0)
    combined_high = bandpass(combined_ir, 2_000.0, 10_000.0)
    reference_peak = peak_index(envelope(reference_high), 0.5, 3.0)
    combined_peak = peak_index(envelope(combined_high), 0.5, 3.0)

    coarse_shift = reference_peak - combined_peak
    radius = round(0.025 * SAMPLE_RATE)
    window_radius = round(0.08 * SAMPLE_RATE)
    ref_window = reference_high[
        reference_peak - window_radius : reference_peak + window_radius
    ]
    candidates = range(coarse_shift - radius, coarse_shift + radius + 1)
    best_shift = coarse_shift
    best_score = -math.inf
    for candidate in candidates:
        shifted = shift_integer(combined_high, candidate)
        candidate_window = shifted[
            reference_peak - window_radius : reference_peak + window_radius
        ]
        score = float(np.dot(ref_window, candidate_window))
        if score > best_score:
            best_score = score
            best_shift = candidate

    aligned_combined_ir = shift_integer(combined_ir, best_shift)
    aligned_combined_high = bandpass(aligned_combined_ir, 2_000.0, 10_000.0)
    fit_start = reference_peak - window_radius
    fit_end = reference_peak + window_radius
    denominator = float(np.dot(reference_high[fit_start:fit_end], reference_high[fit_start:fit_end]))
    door_scale = float(
        np.dot(aligned_combined_high[fit_start:fit_end], reference_high[fit_start:fit_end])
        / denominator
    )
    sub_ir = aligned_combined_ir - door_scale * reference_ir

    reference_low = bandpass(reference_ir, 45.0, 220.0)
    sub_low = bandpass(sub_ir, 45.0, 220.0)
    reference_low_envelope = envelope(reference_low)
    sub_low_envelope = envelope(sub_low)

    search_start = max(0.25, reference_peak / SAMPLE_RATE - 0.30)
    search_end = min(len(reference_ir) / SAMPLE_RATE, reference_peak / SAMPLE_RATE + 0.30)
    door_low_peak = peak_index(reference_low_envelope, search_start, search_end)
    sub_peak = peak_index(sub_low_envelope, search_start, search_end)
    required_delay_ms = (door_low_peak - sub_peak) * 1000.0 / SAMPLE_RATE

    # A local normalized cross-correlation provides a second estimate that uses
    # the full low-frequency wavelet instead of just its envelope maximum.
    correlation_radius = round(0.25 * SAMPLE_RATE)
    center = reference_peak
    window_start = max(0, center - correlation_radius)
    window_end = min(len(reference_low), center + correlation_radius)
    door_segment = reference_low[window_start:window_end]
    sub_segment = sub_low[window_start:window_end]
    correlation = np.correlate(door_segment, sub_segment, mode="full")
    lag = int(np.argmax(np.abs(correlation))) - (len(sub_segment) - 1)
    correlation_delay_ms = lag * 1000.0 / SAMPLE_RATE

    result = {
        "bluetooth_alignment_shift_ms": best_shift * 1000.0 / SAMPLE_RATE,
        "door_scale_between_captures": door_scale,
        "door_high_arrival_ms": reference_peak * 1000.0 / SAMPLE_RATE,
        "door_low_arrival_ms": door_low_peak * 1000.0 / SAMPLE_RATE,
        "sub_arrival_ms": sub_peak * 1000.0 / SAMPLE_RATE,
        "required_esp_delay_ms": required_delay_ms,
        "cross_correlation_delay_ms": correlation_delay_ms,
        "reference_recording_peak_dbfs": 20.0 * math.log10(max(np.max(np.abs(reference_recording)), 1e-12)),
        "combined_recording_peak_dbfs": 20.0 * math.log10(max(np.max(np.abs(combined_recording)), 1e-12)),
    }
    return result


def main() -> None:
    parser = argparse.ArgumentParser()
    subparsers = parser.add_subparsers(dest="command", required=True)
    generate_parser = subparsers.add_parser("generate")
    generate_parser.add_argument("output", type=pathlib.Path)
    burst_parser = subparsers.add_parser("generate-bursts")
    burst_parser.add_argument("output", type=pathlib.Path)
    burst_parser.add_argument("--frequency-hz", type=float, default=110.0)
    burst_parser.add_argument("--amplitude", type=float, default=0.02)
    dual_burst_parser = subparsers.add_parser("generate-dual-bursts")
    dual_burst_parser.add_argument("output", type=pathlib.Path)
    analyse_parser = subparsers.add_parser("analyse")
    analyse_parser.add_argument("reference", type=pathlib.Path)
    analyse_parser.add_argument("combined", type=pathlib.Path)
    analyse_parser.add_argument("--json", type=pathlib.Path)
    args = parser.parse_args()

    if args.command == "generate":
        generate(args.output)
        return
    if args.command == "generate-bursts":
        generate_bursts(args.output, args.frequency_hz, args.amplitude)
        return
    if args.command == "generate-dual-bursts":
        generate_dual_bursts(args.output)
        return
    result = analyse(args.reference, args.combined)
    rendered = json.dumps(result, indent=2, sort_keys=True)
    print(rendered)
    if args.json:
        args.json.write_text(rendered + "\n")


if __name__ == "__main__":
    main()
