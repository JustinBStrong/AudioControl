#include <algorithm>
#include <cmath>
#include <cstdint>
#include <fstream>
#include <iostream>
#include <stdexcept>
#include <string>
#include <vector>

#include "audiocontrol/dsp_engine.hpp"

namespace {

constexpr float kPi = 3.14159265358979323846F;

void writeU16(std::ofstream& stream, std::uint16_t value) {
  const char bytes[] = {static_cast<char>(value & 0xFFU),
                        static_cast<char>((value >> 8U) & 0xFFU)};
  stream.write(bytes, sizeof(bytes));
}

void writeU32(std::ofstream& stream, std::uint32_t value) {
  const char bytes[] = {static_cast<char>(value & 0xFFU),
                        static_cast<char>((value >> 8U) & 0xFFU),
                        static_cast<char>((value >> 16U) & 0xFFU),
                        static_cast<char>((value >> 24U) & 0xFFU)};
  stream.write(bytes, sizeof(bytes));
}

std::uint16_t readU16(std::ifstream& stream) {
  unsigned char bytes[2]{};
  stream.read(reinterpret_cast<char*>(bytes), sizeof(bytes));
  if (!stream) {
    throw std::runtime_error("unexpected end of WAV file");
  }
  return static_cast<std::uint16_t>(bytes[0]) |
         static_cast<std::uint16_t>(bytes[1]) << 8U;
}

std::uint32_t readU32(std::ifstream& stream) {
  unsigned char bytes[4]{};
  stream.read(reinterpret_cast<char*>(bytes), sizeof(bytes));
  if (!stream) {
    throw std::runtime_error("unexpected end of WAV file");
  }
  return static_cast<std::uint32_t>(bytes[0]) |
         static_cast<std::uint32_t>(bytes[1]) << 8U |
         static_cast<std::uint32_t>(bytes[2]) << 16U |
         static_cast<std::uint32_t>(bytes[3]) << 24U;
}

std::vector<audiocontrol::StereoFrame> readWave(const std::string& path) {
  std::ifstream input(path, std::ios::binary);
  if (!input) {
    throw std::runtime_error("cannot open input WAV: " + path);
  }
  char id[4]{};
  input.read(id, 4);
  if (std::string(id, 4) != "RIFF") {
    throw std::runtime_error("input is not a RIFF WAV: " + path);
  }
  (void)readU32(input);
  input.read(id, 4);
  if (std::string(id, 4) != "WAVE") {
    throw std::runtime_error("input is not a WAVE file: " + path);
  }

  std::uint16_t format = 0;
  std::uint16_t channels = 0;
  std::uint32_t sample_rate = 0;
  std::uint16_t bits_per_sample = 0;
  std::vector<std::uint8_t> pcm;
  while (input.read(id, 4)) {
    const auto chunk_size = readU32(input);
    const std::string chunk(id, 4);
    if (chunk == "fmt ") {
      if (chunk_size < 16U) {
        throw std::runtime_error("invalid WAV fmt chunk");
      }
      format = readU16(input);
      channels = readU16(input);
      sample_rate = readU32(input);
      (void)readU32(input);
      (void)readU16(input);
      bits_per_sample = readU16(input);
      input.seekg(static_cast<std::streamoff>(chunk_size - 16U),
                  std::ios::cur);
    } else if (chunk == "data") {
      pcm.resize(chunk_size);
      input.read(reinterpret_cast<char*>(pcm.data()),
                 static_cast<std::streamsize>(pcm.size()));
      if (!input) {
        throw std::runtime_error("truncated WAV data chunk");
      }
    } else {
      input.seekg(static_cast<std::streamoff>(chunk_size), std::ios::cur);
    }
    if ((chunk_size & 1U) != 0U) {
      input.seekg(1, std::ios::cur);
    }
  }
  if (format != 1U || (channels != 1U && channels != 2U) ||
      sample_rate != 48000U || bits_per_sample != 16U || pcm.empty()) {
    throw std::runtime_error(
        "input WAV must be 48 kHz, 16-bit PCM, mono or stereo");
  }
  const std::size_t frame_bytes = channels * sizeof(std::int16_t);
  if (pcm.size() % frame_bytes != 0U) {
    throw std::runtime_error("WAV data is not aligned to complete frames");
  }
  std::vector<audiocontrol::StereoFrame> frames(pcm.size() / frame_bytes);
  for (std::size_t frame = 0; frame < frames.size(); ++frame) {
    const auto sample = [&pcm](std::size_t offset) {
      const auto raw = static_cast<std::uint16_t>(pcm[offset]) |
                       static_cast<std::uint16_t>(pcm[offset + 1U]) << 8U;
      return static_cast<float>(static_cast<std::int16_t>(raw)) / 32768.0F;
    };
    const std::size_t offset = frame * frame_bytes;
    const float left = sample(offset);
    const float right = channels == 2U ? sample(offset + 2U) : left;
    frames[frame] = {left, right};
  }
  return frames;
}

void writeWave(const std::string& path,
               const std::vector<audiocontrol::StereoFrame>& frames) {
  std::ofstream output(path, std::ios::binary);
  if (!output) {
    throw std::runtime_error("cannot open output WAV: " + path);
  }
  constexpr std::uint16_t channels = 2;
  constexpr std::uint16_t bits_per_sample = 16;
  constexpr std::uint32_t sample_rate = 48000;
  constexpr std::uint16_t block_align = channels * bits_per_sample / 8U;
  constexpr std::uint32_t byte_rate = sample_rate * block_align;
  const auto data_size = static_cast<std::uint32_t>(frames.size() * block_align);

  output.write("RIFF", 4);
  writeU32(output, 36U + data_size);
  output.write("WAVEfmt ", 8);
  writeU32(output, 16);
  writeU16(output, 1);
  writeU16(output, channels);
  writeU32(output, sample_rate);
  writeU32(output, byte_rate);
  writeU16(output, block_align);
  writeU16(output, bits_per_sample);
  output.write("data", 4);
  writeU32(output, data_size);
  for (const auto& frame : frames) {
    const auto convert = [](float sample) {
      return static_cast<std::int16_t>(std::lround(
          std::clamp(sample, -1.0F, 1.0F) * 32767.0F));
    };
    writeU16(output, static_cast<std::uint16_t>(convert(frame.left)));
    writeU16(output, static_cast<std::uint16_t>(convert(frame.right)));
  }
}

float argumentValue(int argc, char** argv, const std::string& key,
                    float fallback) {
  for (int index = 1; index + 1 < argc; ++index) {
    if (argv[index] == key) {
      return std::stof(argv[index + 1]);
    }
  }
  return fallback;
}

bool hasArgument(int argc, char** argv, const std::string& key) {
  for (int index = 1; index < argc; ++index) {
    if (argv[index] == key) {
      return true;
    }
  }
  return false;
}

void printUsage() {
  std::cout
      << "Usage: audiocontrol_sim [options]\n"
      << "  --seconds N                 duration (default 3)\n"
      << "  --input-frequency HZ       sine frequency (default 50)\n"
      << "  --input PATH               process a 48 kHz PCM WAV instead\n"
      << "  --delay-ms MS              delay; values above zero enable it\n"
      << "  --delay-disabled           retain time but bypass delay\n"
      << "  --cutoff-hz HZ             low-pass cutoff (default 80)\n"
      << "  --low-pass-disabled        bypass the low-pass filter\n"
      << "  --shelf-transition-hz HZ   bass-shelf transition (default 40)\n"
      << "  --shelf-gain-db DB         shelf gain; nonzero enables it\n"
      << "  --shelf-disabled           retain shelf values but bypass it\n"
      << "  --trim-db DB               final digital attenuation\n"
      << "  --bypass                   bypass all DSP\n"
      << "  --output PATH              output WAV path\n";
}

std::string argumentText(int argc, char** argv, const std::string& key,
                         std::string fallback) {
  for (int index = 1; index + 1 < argc; ++index) {
    if (argv[index] == key) {
      return argv[index + 1];
    }
  }
  return fallback;
}

}  // namespace

int main(int argc, char** argv) {
  try {
    if (hasArgument(argc, argv, "--help") ||
        hasArgument(argc, argv, "-h")) {
      printUsage();
      return 0;
    }
    const float seconds = argumentValue(argc, argv, "--seconds", 3.0F);
    const float frequency_hz =
        argumentValue(argc, argv, "--input-frequency", 50.0F);
    const std::string output_path =
        argumentText(argc, argv, "--output", "audiocontrol-sim.wav");
    const std::string input_path = argumentText(argc, argv, "--input", "");

    auto config = audiocontrol::DspConfiguration::defaults();
    config.revision = 1;
    config.delay_ms = argumentValue(argc, argv, "--delay-ms", 100.0F);
    config.delay_enabled = config.delay_ms > 0.0F &&
                           !hasArgument(argc, argv, "--delay-disabled");
    config.low_pass_hz = argumentValue(argc, argv, "--cutoff-hz", 80.0F);
    config.low_pass_enabled =
        !hasArgument(argc, argv, "--low-pass-disabled");
    config.output_trim_db = argumentValue(argc, argv, "--trim-db", 0.0F);
    config.bass_shelf.transition_hz =
        argumentValue(argc, argv, "--shelf-transition-hz", 40.0F);
    config.bass_shelf.gain_db =
        argumentValue(argc, argv, "--shelf-gain-db", 0.0F);
    config.bass_shelf.enabled =
        std::abs(config.bass_shelf.gain_db) > 0.0001F &&
        !hasArgument(argc, argv, "--shelf-disabled");
    config.bypass_all = hasArgument(argc, argv, "--bypass");

    if (!(seconds > 0.0F) || !(frequency_hz > 0.0F) ||
        frequency_hz >= audiocontrol::DspEngine::kSampleRateHz * 0.5F) {
      std::cerr << "Duration and input frequency must describe a positive "
                   "signal below 24 kHz\n";
      return 2;
    }

    audiocontrol::DspEngine engine;
    const auto error = engine.applyConfiguration(config);
    if (error != audiocontrol::ConfigurationError::None) {
      std::cerr << "Invalid simulator configuration: "
                << audiocontrol::configurationErrorMessage(error) << '\n';
      return 2;
    }

    // Configuration changes are click-free in the real device, so the engine
    // crossfades them over 20 ms. Settle those ramps with silence so an offline
    // file represents the requested steady configuration from its first frame.
    std::vector<audiocontrol::StereoFrame> warmup(960);
    std::vector<audiocontrol::StereoFrame> warmup_output(960);
    engine.process(warmup.data(), warmup_output.data(), warmup.size());
    engine.reset();

    std::vector<audiocontrol::StereoFrame> input;
    if (!input_path.empty()) {
      input = readWave(input_path);
    } else {
      const auto frame_count = static_cast<std::size_t>(
          std::lround(seconds * audiocontrol::DspEngine::kSampleRateHz));
      input.resize(frame_count);
      for (std::size_t index = 0; index < frame_count; ++index) {
        const float time = static_cast<float>(index) /
                           audiocontrol::DspEngine::kSampleRateHz;
        const float sample =
            0.5F * std::sin(2.0F * kPi * frequency_hz * time);
        input[index] = {sample, sample};
      }
    }
    const auto frame_count = input.size();
    std::vector<audiocontrol::StereoFrame> output(frame_count);
    engine.process(input.data(), output.data(), output.size());
    writeWave(output_path, output);

    const auto& telemetry = engine.telemetry();
    std::cout << "Processed " << frame_count << " stereo frames at 48 kHz\n"
              << "delay=" << engine.configuration().delay_ms
              << " ms (" << (engine.configuration().delay_enabled ? "on" : "off")
              << ") low-pass=" << engine.configuration().low_pass_hz
              << " Hz (" << (engine.configuration().low_pass_enabled ? "on" : "off")
              << ") shelf=" << engine.configuration().bass_shelf.gain_db
              << " dB @ " << engine.configuration().bass_shelf.transition_hz
              << " Hz (" << (engine.configuration().bass_shelf.enabled ? "on" : "off")
              << ") trim=" << engine.configuration().output_trim_db << " dB\n"
              << "input peak=" << telemetry.input_peak[0]
              << " output peak=" << telemetry.output_peak[0] << "\n"
              << "wrote " << output_path << '\n';
    return 0;
  } catch (const std::exception& exception) {
    std::cerr << exception.what() << '\n';
    return 1;
  }
}
