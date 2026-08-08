#pragma once

#include <cstddef>
#include <cstdint>
#include <vector>

namespace audiocontrol {

struct StereoFrame {
  float left = 0.0F;
  float right = 0.0F;
};

class StereoDelayLine {
 public:
  StereoDelayLine(float sample_rate_hz, float maximum_delay_ms,
                  float transition_ms = 20.0F);

  bool setDelayMs(float delay_ms);
  StereoFrame process(const StereoFrame& input);
  void reset();

  float delayMs() const;
  std::uint32_t delaySamples() const;
  std::size_t capacityFrames() const;

 private:
  struct PackedStereoFrame {
    std::int16_t left = 0;
    std::int16_t right = 0;
  };

  StereoFrame tap(std::uint32_t delay_samples) const;

  float sample_rate_hz_;
  float maximum_delay_ms_;
  std::vector<PackedStereoFrame> buffer_;
  std::size_t write_index_ = 0;
  std::uint32_t current_delay_samples_ = 0;
  std::uint32_t target_delay_samples_ = 0;
  std::uint32_t transition_length_samples_ = 1;
  std::uint32_t transition_position_ = 0;
};

}  // namespace audiocontrol
