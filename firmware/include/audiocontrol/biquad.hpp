#pragma once

#include <array>

#include "audiocontrol/config.hpp"

namespace audiocontrol {

struct BiquadCoefficients {
  float b0 = 1.0F;
  float b1 = 0.0F;
  float b2 = 0.0F;
  float a1 = 0.0F;
  float a2 = 0.0F;
};

class Biquad {
 public:
  void setCoefficients(const BiquadCoefficients& coefficients);
  float process(float input);
  void reset();

 private:
  BiquadCoefficients coefficients_{};
  float z1_ = 0.0F;
  float z2_ = 0.0F;
};

BiquadCoefficients makeLowPass(float sample_rate_hz, float cutoff_hz, float q);
BiquadCoefficients makeLowShelf(float sample_rate_hz, float frequency_hz,
                                float gain_db);

class ChannelFilterBank {
 public:
  void configure(float sample_rate_hz, float low_pass_hz,
                 bool low_pass_enabled, bool bass_shelf_enabled,
                 float bass_shelf_transition_hz, float bass_shelf_gain_db);
  float process(float input);
  void reset();

 private:
  Biquad bass_shelf_{};
  bool bass_shelf_enabled_ = false;
  std::array<Biquad, 2> low_pass_{};
  bool low_pass_enabled_ = true;
};

}  // namespace audiocontrol
