#include <algorithm>
#include <array>
#include <cmath>
#include <cstdint>
#include <cstdlib>
#include <iostream>
#include <string>
#include <vector>

#include "audiocontrol/delay_line.hpp"
#include "audiocontrol/dsp_engine.hpp"
#include "audiocontrol/wire_protocol.hpp"

namespace {

constexpr float kPi = 3.14159265358979323846F;
int failures = 0;

void expect(bool condition, const std::string& message) {
  if (!condition) {
    ++failures;
    std::cerr << "FAIL: " << message << '\n';
  }
}

void expectNear(float actual, float expected, float tolerance,
                const std::string& message) {
  expect(std::abs(actual - expected) <= tolerance,
         message + " actual=" + std::to_string(actual) +
             " expected=" + std::to_string(expected));
}

void testConfigurationValidation() {
  auto config = audiocontrol::DspConfiguration::defaults();
  expect(audiocontrol::validateConfiguration(config) ==
             audiocontrol::ConfigurationError::None,
         "defaults validate");
  config.delay_ms = 250.01F;
  expect(audiocontrol::validateConfiguration(config) ==
             audiocontrol::ConfigurationError::InvalidDelay,
         "delay above 250 ms rejected");
  config = audiocontrol::DspConfiguration::defaults();
  config.bass_shelf.transition_hz = 19.9F;
  expect(audiocontrol::validateConfiguration(config) ==
             audiocontrol::ConfigurationError::InvalidShelfTransition,
         "bass-shelf transition below range rejected");
  config = audiocontrol::DspConfiguration::defaults();
  config.output_trim_db = -36.0F;
  expect(audiocontrol::validateConfiguration(config) ==
             audiocontrol::ConfigurationError::None,
         "maximum automatic attenuation validates");
  config.output_trim_db = -36.01F;
  expect(audiocontrol::validateConfiguration(config) ==
             audiocontrol::ConfigurationError::InvalidOutputTrim,
         "output attenuation below range rejected");
}

void testDelayImpulse() {
  audiocontrol::StereoDelayLine delay(48000.0F, 250.0F);
  expect(delay.setDelayMs(100.0F), "100 ms delay accepted");
  delay.reset();
  for (std::size_t sample = 0; sample <= 4800; ++sample) {
    const audiocontrol::StereoFrame input =
        sample == 0 ? audiocontrol::StereoFrame{1.0F, -1.0F}
                    : audiocontrol::StereoFrame{};
    const auto output = delay.process(input);
    if (sample < 4800) {
      expectNear(output.left, 0.0F, 1.0e-7F,
                 "delay impulse absent before target");
    } else {
      expectNear(output.left, 32767.0F / 32768.0F, 1.0e-7F,
                 "left impulse appears at 4800 samples");
      expectNear(output.right, -1.0F, 1.0e-7F,
                 "right impulse appears at 4800 samples");
    }
  }
}

void testEngineAppliesConfiguredDelay() {
  auto config = audiocontrol::DspConfiguration::defaults();
  config.revision = 1;
  config.delay_enabled = true;
  config.delay_ms = 10.0F;
  config.low_pass_enabled = false;

  audiocontrol::DspEngine engine;
  expect(engine.applyConfiguration(config) ==
             audiocontrol::ConfigurationError::None,
         "engine delay configuration accepted");

  // Let the live-change crossfade settle, then clear the delay line so this
  // measures the configured steady state rather than the transition itself.
  std::array<audiocontrol::StereoFrame, 960> warmup{};
  std::array<audiocontrol::StereoFrame, 960> warmup_output{};
  engine.process(warmup.data(), warmup_output.data(), warmup.size());
  engine.reset();

  std::array<audiocontrol::StereoFrame, 481> input{};
  std::array<audiocontrol::StereoFrame, 481> output{};
  input[0] = {0.5F, -0.5F};
  engine.process(input.data(), output.data(), output.size());
  for (std::size_t sample = 0; sample < 480; ++sample) {
    expectNear(output[sample].left, 0.0F, 1.0e-7F,
               "engine output is silent before configured delay");
  }
  expectNear(output[480].left, 0.5F, 4.0e-5F,
             "engine emits left impulse after 10 ms");
  expectNear(output[480].right, -0.5F, 4.0e-5F,
             "engine emits right impulse after 10 ms");
}

float measuredGain(float frequency_hz, bool low_pass_enabled) {
  constexpr std::size_t frame_count = 96000;
  std::vector<audiocontrol::StereoFrame> input(frame_count);
  std::vector<audiocontrol::StereoFrame> output(frame_count);
  for (std::size_t sample = 0; sample < frame_count; ++sample) {
    const float value = 0.1F * std::sin(2.0F * kPi * frequency_hz *
                                       static_cast<float>(sample) / 48000.0F);
    input[sample] = {value, value};
  }
  auto config = audiocontrol::DspConfiguration::defaults();
  config.revision = 1;
  config.delay_enabled = false;
  config.low_pass_enabled = low_pass_enabled;
  config.low_pass_hz = 80.0F;
  config.output_trim_db = 0.0F;
  audiocontrol::DspEngine engine;
  expect(engine.applyConfiguration(config) ==
             audiocontrol::ConfigurationError::None,
         "frequency response config accepted");
  engine.process(input.data(), output.data(), frame_count);
  double input_energy = 0.0;
  double output_energy = 0.0;
  for (std::size_t sample = 48000; sample < frame_count; ++sample) {
    input_energy += static_cast<double>(input[sample].left) * input[sample].left;
    output_energy +=
        static_cast<double>(output[sample].left) * output[sample].left;
  }
  return static_cast<float>(std::sqrt(output_energy / input_energy));
}

void testLowPassResponse() {
  const float cutoff_gain = measuredGain(80.0F, true);
  expectNear(20.0F * std::log10(cutoff_gain), -6.02F, 0.3F,
             "LR24 is -6 dB at cutoff");
  const float voice_gain = measuredGain(1000.0F, true);
  expect(20.0F * std::log10(voice_gain) < -80.0F,
         "80 Hz LR24 attenuates 1 kHz by at least 80 dB");
  expectNear(measuredGain(1000.0F, false), 1.0F, 0.0001F,
             "disabled low-pass is transparent");
}

float measuredShelfGain(float frequency_hz) {
  constexpr std::size_t frame_count = 96000;
  std::vector<audiocontrol::StereoFrame> input(frame_count);
  std::vector<audiocontrol::StereoFrame> output(frame_count);
  for (std::size_t sample = 0; sample < frame_count; ++sample) {
    const float value = 0.01F * std::sin(2.0F * kPi * frequency_hz *
                                        static_cast<float>(sample) / 48000.0F);
    input[sample] = {value, value};
  }
  auto config = audiocontrol::DspConfiguration::defaults();
  config.low_pass_enabled = false;
  config.bass_shelf.enabled = true;
  config.bass_shelf.transition_hz = 50.0F;
  config.bass_shelf.gain_db = 6.0F;
  audiocontrol::DspEngine engine;
  expect(engine.applyConfiguration(config) ==
             audiocontrol::ConfigurationError::None,
         "low-shelf config accepted");
  engine.process(input.data(), output.data(), frame_count);
  double input_energy = 0.0;
  double output_energy = 0.0;
  for (std::size_t sample = 48000; sample < frame_count; ++sample) {
    input_energy += static_cast<double>(input[sample].left) * input[sample].left;
    output_energy +=
        static_cast<double>(output[sample].left) * output[sample].left;
  }
  return static_cast<float>(std::sqrt(output_energy / input_energy));
}

void testLowShelfResponse() {
  expectNear(20.0F * std::log10(measuredShelfGain(50.0F)), 3.0F, 0.15F,
             "low shelf is half its dB gain at transition");
  expectNear(20.0F * std::log10(measuredShelfGain(1000.0F)), 0.0F, 0.1F,
             "low shelf leaves upper frequencies unchanged");
}

void testWireRoundTrip() {
  auto config = audiocontrol::DspConfiguration::defaults();
  config.revision = 42;
  config.delay_ms = 123.456F;
  config.low_pass_hz = 91.2F;
  config.output_trim_db = -4.25F;
  config.bass_shelf = {true, 47.3F, 2.5F};
  auto packet = audiocontrol::wire::encodeConfiguration(config);
  audiocontrol::DspConfiguration decoded;
  expect(audiocontrol::wire::decodeConfiguration(
             packet.data(), packet.size(), decoded) ==
             audiocontrol::wire::PacketError::None,
         "configuration wire packet decodes");
  expect(decoded.revision == 42, "revision round trips");
  expectNear(decoded.delay_ms, 123.456F, 0.001F, "delay round trips");
  expectNear(decoded.bass_shelf.transition_hz, 47.3F, 0.05F,
             "bass-shelf transition round trips");
  expectNear(decoded.bass_shelf.gain_db, 2.5F, 0.01F,
             "bass-shelf gain round trips");
  expect(decoded.bass_shelf.enabled, "bass shelf enable round trips");
  packet[12] ^= 0x01U;
  expect(audiocontrol::wire::decodeConfiguration(
             packet.data(), packet.size(), decoded) ==
             audiocontrol::wire::PacketError::InvalidCrc,
         "corrupt configuration rejected by CRC");
}

void testDefaultWireVector() {
  const std::array<std::uint8_t, 22> expected = {
      0x02, 0x02, 0x16, 0x00, 0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
      0x00, 0x20, 0x03, 0x00, 0x00, 0x90, 0x01, 0x00, 0x00, 0xBB, 0x39};
  auto config = audiocontrol::DspConfiguration::defaults();
  config.revision = 1;
  const auto packet = audiocontrol::wire::encodeConfiguration(config);
  expect(packet == expected, "default packet matches canonical Swift vector");
}

void testClippingTelemetry() {
  auto config = audiocontrol::DspConfiguration::defaults();
  config.bypass_all = true;
  config.output_trim_db = 0.0F;
  audiocontrol::DspEngine engine;
  expect(engine.applyConfiguration(config) ==
             audiocontrol::ConfigurationError::None,
         "bypass config accepted");
  std::array<audiocontrol::StereoFrame, 1000> input{};
  std::array<audiocontrol::StereoFrame, 1000> output{};
  std::fill(input.begin(), input.end(), audiocontrol::StereoFrame{1.1F, -1.2F});
  engine.process(input.data(), output.data(), input.size());
  expect(engine.telemetry().input_clipped, "input clip latches");
  expect(engine.telemetry().output_clipped, "output clip latches");
  expectNear(output.back().left, 1.0F, 0.0F, "positive output saturates");
  expectNear(output.back().right, -1.0F, 0.0F, "negative output saturates");
  engine.clearClipLatches();
  expect(!engine.telemetry().input_clipped &&
             !engine.telemetry().output_clipped,
         "clip latches clear");
}

void testOutputTrimRamps() {
  auto config = audiocontrol::DspConfiguration::defaults();
  config.low_pass_enabled = false;
  config.output_trim_db = 0.0F;
  audiocontrol::DspEngine engine;
  engine.applyConfiguration(config);
  std::array<audiocontrol::StereoFrame, 1000> input{};
  std::array<audiocontrol::StereoFrame, 1000> output{};
  std::fill(input.begin(), input.end(), audiocontrol::StereoFrame{0.5F, 0.5F});
  engine.process(input.data(), output.data(), input.size());

  config.revision = 1;
  config.output_trim_db = -18.0F;
  engine.applyConfiguration(config);
  engine.process(input.data(), output.data(), input.size());
  float maximum_step = 0.0F;
  for (std::size_t index = 1; index < output.size(); ++index) {
    maximum_step = std::max(maximum_step,
                            std::abs(output[index].left - output[index - 1].left));
  }
  expect(maximum_step < 0.001F, "live output trim is sample-ramped");
  expectNear(output.back().left, 0.5F * std::pow(10.0F, -18.0F / 20.0F),
             0.0001F, "output trim reaches requested target");
}

}  // namespace

int main() {
  testConfigurationValidation();
  testDelayImpulse();
  testEngineAppliesConfiguredDelay();
  testLowPassResponse();
  testLowShelfResponse();
  testWireRoundTrip();
  testDefaultWireVector();
  testClippingTelemetry();
  testOutputTrimRamps();
  if (failures != 0) {
    std::cerr << failures << " test assertion(s) failed\n";
    return EXIT_FAILURE;
  }
  std::cout << "All AudioControl DSP tests passed\n";
  return EXIT_SUCCESS;
}
