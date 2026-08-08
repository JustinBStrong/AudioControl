#pragma once

#include <array>
#include <cstddef>
#include <cstdint>

#include "audiocontrol/config.hpp"
#include "audiocontrol/telemetry.hpp"

namespace audiocontrol::wire {

inline constexpr std::uint8_t kProtocolVersion = 2;
inline constexpr std::size_t kConfigurationPacketSize = 22;
inline constexpr std::size_t kTelemetryPacketSize = 20;
inline constexpr std::size_t kCommandPacketSize = 8;

inline constexpr char kServiceUuid[] =
    "7C1C0001-7A4D-4E6B-9D2A-5E4143554449";
inline constexpr char kConfigurationUuid[] =
    "7C1C0002-7A4D-4E6B-9D2A-5E4143554449";
inline constexpr char kTelemetryUuid[] =
    "7C1C0003-7A4D-4E6B-9D2A-5E4143554449";
inline constexpr char kCommandUuid[] =
    "7C1C0004-7A4D-4E6B-9D2A-5E4143554449";

using ConfigurationPacket = std::array<std::uint8_t, kConfigurationPacketSize>;
using TelemetryPacket = std::array<std::uint8_t, kTelemetryPacketSize>;
using CommandPacket = std::array<std::uint8_t, kCommandPacketSize>;

enum class PacketError : std::uint8_t {
  None = 0,
  UnsupportedVersion,
  InvalidLength,
  InvalidCrc,
  InvalidRange,
  ReservedFieldSet,
  StaleRevision,
};

enum class CommandOpcode : std::uint8_t {
  Save = 1,
  RestoreDefaults = 2,
  Reboot = 3,
  ClearClip = 4,
};

enum class CommandStatus : std::uint8_t {
  Ok = 0,
  Version = 1,
  Length = 2,
  Crc = 3,
  Range = 4,
  Reserved = 5,
  StaleRevision = 6,
  Unavailable = 7,
  Internal = 8,
};

struct DecodedCommand {
  CommandOpcode opcode = CommandOpcode::Save;
  std::uint32_t request_id = 0;
};

std::uint16_t crc16CcittFalse(const std::uint8_t* data, std::size_t size);
ConfigurationPacket encodeConfiguration(const DspConfiguration& config);
PacketError decodeConfiguration(const std::uint8_t* data, std::size_t size,
                                DspConfiguration& output,
                                std::uint32_t minimum_revision = 0);
TelemetryPacket encodeTelemetry(const AudioTelemetry& telemetry,
                                std::uint32_t configuration_revision,
                                bool codec_ready, bool audio_running,
                                bool settings_dirty);
PacketError decodeCommand(const std::uint8_t* data, std::size_t size,
                          DecodedCommand& output);
CommandPacket encodeCommandStatus(CommandStatus status,
                                  std::uint32_t request_id);

}  // namespace audiocontrol::wire
