#pragma once

#include <array>
#include <cstdint>

namespace audiocontrol {

struct AudioTelemetry {
  std::array<float, 2> input_peak{0.0F, 0.0F};
  std::array<float, 2> output_peak{0.0F, 0.0F};
  bool input_clipped = false;
  bool output_clipped = false;
  std::uint32_t underrun_count = 0;
};

}  // namespace audiocontrol
