#include "audiocontrol/biquad.hpp"

#include <algorithm>
#include <cmath>

namespace audiocontrol {
namespace {

constexpr float kPi = 3.14159265358979323846F;

BiquadCoefficients normalize(float b0, float b1, float b2, float a0,
                             float a1, float a2) {
  return {b0 / a0, b1 / a0, b2 / a0, a1 / a0, a2 / a0};
}

}  // namespace

void Biquad::setCoefficients(const BiquadCoefficients& coefficients) {
  coefficients_ = coefficients;
}

float Biquad::process(float input) {
  const float output = coefficients_.b0 * input + z1_;
  z1_ = coefficients_.b1 * input - coefficients_.a1 * output + z2_;
  z2_ = coefficients_.b2 * input - coefficients_.a2 * output;
  return output;
}

void Biquad::reset() {
  z1_ = 0.0F;
  z2_ = 0.0F;
}

BiquadCoefficients makeLowPass(float sample_rate_hz, float cutoff_hz,
                               float q) {
  const float omega = 2.0F * kPi * cutoff_hz / sample_rate_hz;
  const float cosine = std::cos(omega);
  const float sine = std::sin(omega);
  const float alpha = sine / (2.0F * q);
  const float b0 = (1.0F - cosine) * 0.5F;
  const float b1 = 1.0F - cosine;
  const float b2 = b0;
  const float a0 = 1.0F + alpha;
  const float a1 = -2.0F * cosine;
  const float a2 = 1.0F - alpha;
  return normalize(b0, b1, b2, a0, a1, a2);
}

BiquadCoefficients makeLowShelf(float sample_rate_hz, float frequency_hz,
                                float gain_db) {
  const float amplitude = std::pow(10.0F, gain_db / 40.0F);
  const float omega = 2.0F * kPi * frequency_hz / sample_rate_hz;
  const float cosine = std::cos(omega);
  const float alpha = std::sin(omega) * std::sqrt(2.0F) * 0.5F;
  const float two_sqrt_a_alpha = 2.0F * std::sqrt(amplitude) * alpha;
  const float a_plus_one = amplitude + 1.0F;
  const float a_minus_one = amplitude - 1.0F;
  const float b0 = amplitude *
                   (a_plus_one - a_minus_one * cosine + two_sqrt_a_alpha);
  const float b1 = 2.0F * amplitude *
                   (a_minus_one - a_plus_one * cosine);
  const float b2 = amplitude *
                   (a_plus_one - a_minus_one * cosine - two_sqrt_a_alpha);
  const float a0 = a_plus_one + a_minus_one * cosine + two_sqrt_a_alpha;
  const float a1 = -2.0F * (a_minus_one + a_plus_one * cosine);
  const float a2 = a_plus_one + a_minus_one * cosine - two_sqrt_a_alpha;
  return normalize(b0, b1, b2, a0, a1, a2);
}

void ChannelFilterBank::configure(
    float sample_rate_hz, float low_pass_hz, bool low_pass_enabled,
    bool bass_shelf_enabled, float bass_shelf_transition_hz,
    float bass_shelf_gain_db) {
  bass_shelf_enabled_ = bass_shelf_enabled;
  low_pass_enabled_ = low_pass_enabled;
  bass_shelf_.setCoefficients(makeLowShelf(
      sample_rate_hz, bass_shelf_transition_hz, bass_shelf_gain_db));
  bass_shelf_.reset();
  constexpr float kButterworthQ = 0.7071067811865475F;
  const auto low_pass =
      makeLowPass(sample_rate_hz, low_pass_hz, kButterworthQ);
  for (auto& stage : low_pass_) {
    stage.setCoefficients(low_pass);
    stage.reset();
  }
}

float ChannelFilterBank::process(float input) {
  float output = input;
  if (bass_shelf_enabled_) {
    output = bass_shelf_.process(output);
  }
  if (low_pass_enabled_) {
    for (auto& stage : low_pass_) {
      output = stage.process(output);
    }
  }
  return output;
}

void ChannelFilterBank::reset() {
  bass_shelf_.reset();
  for (auto& stage : low_pass_) {
    stage.reset();
  }
}

}  // namespace audiocontrol
