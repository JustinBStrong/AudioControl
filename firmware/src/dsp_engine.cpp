#include "audiocontrol/dsp_engine.hpp"

#include <algorithm>
#include <cmath>

namespace audiocontrol {
namespace {

bool filterConfigurationChanged(const DspConfiguration& lhs,
                                const DspConfiguration& rhs) {
  if (lhs.low_pass_enabled != rhs.low_pass_enabled ||
      lhs.low_pass_hz != rhs.low_pass_hz ||
      lhs.bass_shelf.enabled != rhs.bass_shelf.enabled ||
      lhs.bass_shelf.transition_hz != rhs.bass_shelf.transition_hz ||
      lhs.bass_shelf.gain_db != rhs.bass_shelf.gain_db) {
    return true;
  }
  return false;
}

float decibelsToLinear(float decibels) {
  return std::pow(10.0F, decibels / 20.0F);
}

}  // namespace

DspEngine::DspEngine() {
  configureFilterBank(active_filters_, configuration_);
  configureFilterBank(pending_filters_, configuration_);
  delay_.setDelayMs(configuration_.delay_ms);
  delay_.reset();
  output_gain_.reset(decibelsToLinear(configuration_.output_trim_db));
  delay_mix_.reset(configuration_.delay_enabled ? 1.0F : 0.0F);
  bypass_mix_.reset(configuration_.bypass_all ? 1.0F : 0.0F);
}

void DspEngine::LinearRamp::reset(float value) {
  current = value;
  target = value;
  increment = 0.0F;
  remaining = 0;
}

void DspEngine::LinearRamp::setTarget(float value, std::uint32_t samples) {
  target = value;
  if (samples == 0 || current == target) {
    reset(value);
    return;
  }
  remaining = samples;
  increment = (target - current) / static_cast<float>(samples);
}

float DspEngine::LinearRamp::next() {
  if (remaining > 0) {
    current += increment;
    --remaining;
    if (remaining == 0) {
      current = target;
    }
  }
  return current;
}

void DspEngine::configureFilterBank(StereoFilters& filters,
                                    const DspConfiguration& config) {
  for (auto& channel : filters) {
    channel.configure(kSampleRateHz, config.low_pass_hz,
                      config.low_pass_enabled, config.bass_shelf.enabled,
                      config.bass_shelf.transition_hz,
                      config.bass_shelf.gain_db);
  }
}

ConfigurationError DspEngine::applyConfiguration(
    const DspConfiguration& config) {
  const auto error = validateConfiguration(config);
  if (error != ConfigurationError::None) {
    return error;
  }

  if (filterConfigurationChanged(configuration_, config)) {
    if (filter_transition_position_ < filter_transition_length_samples_ &&
        filter_transition_position_ * 2U >= filter_transition_length_samples_) {
      active_filters_ = pending_filters_;
    }
    pending_filters_ = StereoFilters{};
    configureFilterBank(pending_filters_, config);
    filter_transition_position_ = 0;
  }

  delay_.setDelayMs(config.delay_ms);
  output_gain_.setTarget(decibelsToLinear(config.output_trim_db),
                         filter_transition_length_samples_);
  delay_mix_.setTarget(config.delay_enabled ? 1.0F : 0.0F,
                       filter_transition_length_samples_);
  bypass_mix_.setTarget(config.bypass_all ? 1.0F : 0.0F,
                        filter_transition_length_samples_);
  configuration_ = config;
  return ConfigurationError::None;
}

StereoFrame DspEngine::processFilters(StereoFilters& filters,
                                      const StereoFrame& input) {
  return {filters[0].process(input.left), filters[1].process(input.right)};
}

void DspEngine::process(const StereoFrame* input, StereoFrame* output,
                        std::size_t frame_count) {
  telemetry_.input_peak = {0.0F, 0.0F};
  telemetry_.output_peak = {0.0F, 0.0F};

  for (std::size_t index = 0; index < frame_count; ++index) {
    const auto& source = input[index];
    telemetry_.input_peak[0] =
        std::max(telemetry_.input_peak[0], std::abs(source.left));
    telemetry_.input_peak[1] =
        std::max(telemetry_.input_peak[1], std::abs(source.right));
    telemetry_.input_clipped = telemetry_.input_clipped ||
                               std::abs(source.left) >= 1.0F ||
                               std::abs(source.right) >= 1.0F;

    StereoFrame filtered;
    if (filter_transition_position_ < filter_transition_length_samples_) {
      const auto active = processFilters(active_filters_, source);
      const auto pending = processFilters(pending_filters_, source);
      const float alpha = static_cast<float>(filter_transition_position_) /
                          static_cast<float>(filter_transition_length_samples_);
      filtered.left = active.left + alpha * (pending.left - active.left);
      filtered.right = active.right + alpha * (pending.right - active.right);
      ++filter_transition_position_;
      if (filter_transition_position_ >= filter_transition_length_samples_) {
        active_filters_ = pending_filters_;
      }
    } else {
      filtered = processFilters(active_filters_, source);
    }

    const StereoFrame delayed = delay_.process(filtered);
    const float delay_mix = delay_mix_.next();
    StereoFrame processed{
        filtered.left + delay_mix * (delayed.left - filtered.left),
        filtered.right + delay_mix * (delayed.right - filtered.right)};
    const float output_gain = output_gain_.next();
    processed.left *= output_gain;
    processed.right *= output_gain;
    const float bypass_mix = bypass_mix_.next();
    processed.left += bypass_mix * (source.left - processed.left);
    processed.right += bypass_mix * (source.right - processed.right);

    telemetry_.output_peak[0] =
        std::max(telemetry_.output_peak[0], std::abs(processed.left));
    telemetry_.output_peak[1] =
        std::max(telemetry_.output_peak[1], std::abs(processed.right));
    telemetry_.output_clipped = telemetry_.output_clipped ||
                                std::abs(processed.left) >= 1.0F ||
                                std::abs(processed.right) >= 1.0F;
    output[index].left = std::clamp(processed.left, -1.0F, 1.0F);
    output[index].right = std::clamp(processed.right, -1.0F, 1.0F);
  }
}

void DspEngine::reset() {
  delay_.reset();
  for (auto& channel : active_filters_) {
    channel.reset();
  }
  for (auto& channel : pending_filters_) {
    channel.reset();
  }
  clearClipLatches();
  telemetry_.input_peak = {0.0F, 0.0F};
  telemetry_.output_peak = {0.0F, 0.0F};
}

const DspConfiguration& DspEngine::configuration() const {
  return configuration_;
}

const AudioTelemetry& DspEngine::telemetry() const { return telemetry_; }

void DspEngine::clearClipLatches() {
  telemetry_.input_clipped = false;
  telemetry_.output_clipped = false;
}

void DspEngine::clearUnderruns() { telemetry_.underrun_count = 0; }

void DspEngine::incrementUnderruns() { ++telemetry_.underrun_count; }

}  // namespace audiocontrol
