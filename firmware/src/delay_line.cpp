#include "audiocontrol/delay_line.hpp"

#include <algorithm>
#include <cmath>
#include <limits>

namespace audiocontrol {

StereoDelayLine::StereoDelayLine(float sample_rate_hz, float maximum_delay_ms,
                                 float transition_ms)
    : sample_rate_hz_(sample_rate_hz), maximum_delay_ms_(maximum_delay_ms) {
  const auto maximum_samples = static_cast<std::size_t>(
      std::ceil(sample_rate_hz_ * maximum_delay_ms_ / 1000.0F));
  buffer_.resize(maximum_samples + 1U);
  transition_length_samples_ = std::max<std::uint32_t>(
      1U, static_cast<std::uint32_t>(
              std::lround(sample_rate_hz_ * transition_ms / 1000.0F)));
  transition_position_ = transition_length_samples_;
}

bool StereoDelayLine::setDelayMs(float delay_ms) {
  if (!std::isfinite(delay_ms) || delay_ms < 0.0F ||
      delay_ms > maximum_delay_ms_) {
    return false;
  }
  const auto requested_samples = static_cast<std::uint32_t>(
      std::lround(sample_rate_hz_ * delay_ms / 1000.0F));
  if (requested_samples == target_delay_samples_) {
    return true;
  }

  if (transition_position_ < transition_length_samples_) {
    const float alpha = static_cast<float>(transition_position_) /
                        static_cast<float>(transition_length_samples_);
    const float interpolated =
        static_cast<float>(current_delay_samples_) +
        alpha * static_cast<float>(static_cast<std::int32_t>(target_delay_samples_) -
                                   static_cast<std::int32_t>(current_delay_samples_));
    current_delay_samples_ =
        static_cast<std::uint32_t>(std::max(0.0F, std::round(interpolated)));
  } else {
    current_delay_samples_ = target_delay_samples_;
  }
  target_delay_samples_ = requested_samples;
  transition_position_ = 0;
  return true;
}

StereoFrame StereoDelayLine::tap(std::uint32_t delay_samples) const {
  const std::size_t offset = delay_samples % buffer_.size();
  const std::size_t index =
      (write_index_ + buffer_.size() - offset) % buffer_.size();
  return {static_cast<float>(buffer_[index].left) / 32768.0F,
          static_cast<float>(buffer_[index].right) / 32768.0F};
}

StereoFrame StereoDelayLine::process(const StereoFrame& input) {
  const auto pack = [](float sample) {
    const float limited = std::clamp(sample, -1.0F, 0.999969482421875F);
    return static_cast<std::int16_t>(std::lround(limited * 32768.0F));
  };
  buffer_[write_index_] = {pack(input.left), pack(input.right)};
  const auto read = [this, &input](std::uint32_t delay_samples) {
    return delay_samples == 0 ? input : tap(delay_samples);
  };
  StereoFrame output;
  if (transition_position_ < transition_length_samples_) {
    const float alpha = static_cast<float>(transition_position_) /
                        static_cast<float>(transition_length_samples_);
    const StereoFrame current = read(current_delay_samples_);
    const StereoFrame target = read(target_delay_samples_);
    output.left = current.left + alpha * (target.left - current.left);
    output.right = current.right + alpha * (target.right - current.right);
    ++transition_position_;
    if (transition_position_ >= transition_length_samples_) {
      current_delay_samples_ = target_delay_samples_;
    }
  } else {
    output = read(target_delay_samples_);
  }
  write_index_ = (write_index_ + 1U) % buffer_.size();
  return output;
}

void StereoDelayLine::reset() {
  std::fill(buffer_.begin(), buffer_.end(), PackedStereoFrame{});
  write_index_ = 0;
  current_delay_samples_ = target_delay_samples_;
  transition_position_ = transition_length_samples_;
}

float StereoDelayLine::delayMs() const {
  return 1000.0F * static_cast<float>(target_delay_samples_) / sample_rate_hz_;
}

std::uint32_t StereoDelayLine::delaySamples() const {
  return target_delay_samples_;
}

std::size_t StereoDelayLine::capacityFrames() const { return buffer_.size(); }

}  // namespace audiocontrol
