cmake_minimum_required(VERSION 3.20)
project(AudioControlFirmwareCore VERSION 0.1.0 LANGUAGES CXX)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_CXX_EXTENSIONS OFF)

add_library(audiocontrol_core
  src/biquad.cpp
  src/config.cpp
  src/delay_line.cpp
  src/dsp_engine.cpp
  src/wire_protocol.cpp
)
target_include_directories(audiocontrol_core PUBLIC include)
target_compile_options(audiocontrol_core PRIVATE
  $<$<CXX_COMPILER_ID:AppleClang,Clang,GNU>:-Wall;-Wextra;-Wpedantic;-Werror>
)

add_executable(audiocontrol_sim host/simulator.cpp)
target_link_libraries(audiocontrol_sim PRIVATE audiocontrol_core)

enable_testing()
add_executable(audiocontrol_tests tests/test_dsp.cpp)
target_link_libraries(audiocontrol_tests PRIVATE audiocontrol_core)
add_test(NAME audiocontrol_tests COMMAND audiocontrol_tests)
