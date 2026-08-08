#pragma once

#include <cstdint>

namespace audiocontrol {

inline constexpr std::uint16_t kConfigurationVersion = 2;

struct BassShelfConfiguration {
  bool enabled = false;
  float transition_hz = 40.0F;
  float gain_db = 0.0F;
};

struct DspConfiguration {
  std::uint16_t version = kConfigurationVersion;
  std::uint32_t revision = 0;
  bool delay_enabled = false;
  bool low_pass_enabled = true;
  bool bypass_all = false;
  float delay_ms = 0.0F;
  float low_pass_hz = 80.0F;
  float output_trim_db = 0.0F;
  BassShelfConfiguration bass_shelf{};

  static DspConfiguration defaults();
};

enum class ConfigurationError : std::uint8_t {
  None = 0,
  UnsupportedVersion,
  InvalidRevision,
  InvalidDelay,
  InvalidLowPass,
  InvalidOutputTrim,
  InvalidShelfTransition,
  InvalidShelfGain,
  NonFiniteValue,
};

ConfigurationError validateConfiguration(const DspConfiguration& config);
const char* configurationErrorMessage(ConfigurationError error);

}  // namespace audiocontrol
