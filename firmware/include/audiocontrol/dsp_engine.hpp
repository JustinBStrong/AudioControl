#pragma once

#include <array>
#include <cstddef>

#include "audiocontrol/biquad.hpp"
#include "audiocontrol/config.hpp"
#include "audiocontrol/delay_line.hpp"
#include "audiocontrol/telemetry.hpp"

namespace audiocontrol {

class DspEngine {
 public:
  static constexpr float kSampleRateHz = 48000.0F;
  static constexpr float kMaximumDelayMs = 250.0F;

  DspEngine();

  ConfigurationError applyConfiguration(const DspConfiguration& config);
  void process(const StereoFrame* input, StereoFrame* output,
               std::size_t frame_count);
  void reset();

  const DspConfiguration& configuration() const;
  const AudioTelemetry& telemetry() const;
  void clearClipLatches();
  void clearUnderruns();
  void incrementUnderruns();

 private:
  using StereoFilters = std::array<ChannelFilterBank, 2>;

  struct LinearRamp {
    float current = 0.0F;
    float target = 0.0F;
    float increment = 0.0F;
    std::uint32_t remaining = 0;

    void reset(float value);
    void setTarget(float value, std::uint32_t samples);
    float next();
  };

  static void configureFilterBank(StereoFilters& filters,
                                  const DspConfiguration& config);
  StereoFrame processFilters(StereoFilters& filters, const StereoFrame& input);

  DspConfiguration configuration_ = DspConfiguration::defaults();
  StereoDelayLine delay_{kSampleRateHz, kMaximumDelayMs};
  StereoFilters active_filters_{};
  StereoFilters pending_filters_{};
  std::uint32_t filter_transition_length_samples_ = 960;
  std::uint32_t filter_transition_position_ = 960;
  LinearRamp output_gain_{};
  LinearRamp delay_mix_{};
  LinearRamp bypass_mix_{};
  AudioTelemetry telemetry_{};
};

}  // namespace audiocontrol
