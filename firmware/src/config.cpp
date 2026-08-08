#include "audiocontrol/config.hpp"

#include <cmath>

namespace audiocontrol {

DspConfiguration DspConfiguration::defaults() {
  return DspConfiguration{};
}

ConfigurationError validateConfiguration(const DspConfiguration& config) {
  if (config.version != kConfigurationVersion) {
    return ConfigurationError::UnsupportedVersion;
  }

  const auto finite = [](float value) { return std::isfinite(value); };
  if (!finite(config.delay_ms) || !finite(config.low_pass_hz) ||
      !finite(config.output_trim_db) ||
      !finite(config.bass_shelf.transition_hz) ||
      !finite(config.bass_shelf.gain_db)) {
    return ConfigurationError::NonFiniteValue;
  }
  if (config.delay_ms < 0.0F || config.delay_ms > 250.0F) {
    return ConfigurationError::InvalidDelay;
  }
  if (config.low_pass_hz < 40.0F || config.low_pass_hz > 160.0F) {
    return ConfigurationError::InvalidLowPass;
  }
  if (config.output_trim_db < -36.0F || config.output_trim_db > 0.0F) {
    return ConfigurationError::InvalidOutputTrim;
  }
  if (config.bass_shelf.transition_hz < 20.0F ||
      config.bass_shelf.transition_hz > 100.0F) {
    return ConfigurationError::InvalidShelfTransition;
  }
  if (config.bass_shelf.gain_db < -6.0F ||
      config.bass_shelf.gain_db > 6.0F) {
    return ConfigurationError::InvalidShelfGain;
  }
  return ConfigurationError::None;
}

const char* configurationErrorMessage(ConfigurationError error) {
  switch (error) {
    case ConfigurationError::None:
      return "valid";
    case ConfigurationError::UnsupportedVersion:
      return "unsupported configuration version";
    case ConfigurationError::InvalidRevision:
      return "invalid revision";
    case ConfigurationError::InvalidDelay:
      return "delay must be between 0 and 250 ms";
    case ConfigurationError::InvalidLowPass:
      return "low-pass cutoff must be between 40 and 160 Hz";
    case ConfigurationError::InvalidOutputTrim:
      return "output trim must be between -36 and 0 dB";
    case ConfigurationError::InvalidShelfTransition:
      return "bass-shelf transition must be between 20 and 100 Hz";
    case ConfigurationError::InvalidShelfGain:
      return "bass-shelf gain must be between -6 and +6 dB";
    case ConfigurationError::NonFiniteValue:
      return "configuration contains a non-finite value";
  }
  return "unknown configuration error";
}

}  // namespace audiocontrol
