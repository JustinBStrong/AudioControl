#include "audiocontrol/wire_protocol.hpp"

#include <algorithm>
#include <cmath>
#include <cstring>

namespace audiocontrol::wire {
namespace {

void writeU16(std::uint8_t* destination, std::uint16_t value) {
  destination[0] = static_cast<std::uint8_t>(value & 0xFFU);
  destination[1] = static_cast<std::uint8_t>((value >> 8U) & 0xFFU);
}

void writeI16(std::uint8_t* destination, std::int16_t value) {
  writeU16(destination, static_cast<std::uint16_t>(value));
}

void writeU32(std::uint8_t* destination, std::uint32_t value) {
  for (std::size_t index = 0; index < 4; ++index) {
    destination[index] =
        static_cast<std::uint8_t>((value >> (index * 8U)) & 0xFFU);
  }
}

std::uint16_t readU16(const std::uint8_t* source) {
  return static_cast<std::uint16_t>(source[0]) |
         static_cast<std::uint16_t>(source[1]) << 8U;
}

std::int16_t readI16(const std::uint8_t* source) {
  return static_cast<std::int16_t>(readU16(source));
}

std::uint32_t readU32(const std::uint8_t* source) {
  std::uint32_t value = 0;
  for (std::size_t index = 0; index < 4; ++index) {
    value |= static_cast<std::uint32_t>(source[index]) << (index * 8U);
  }
  return value;
}

std::int16_t amplitudeToCentiDb(float amplitude) {
  if (!std::isfinite(amplitude) || amplitude <= 0.0000158489F) {
    return -9600;
  }
  const float decibels = 20.0F * std::log10(amplitude);
  return static_cast<std::int16_t>(
      std::clamp(std::lround(decibels * 100.0F), -9600L, 1200L));
}

}  // namespace

std::uint16_t crc16CcittFalse(const std::uint8_t* data, std::size_t size) {
  std::uint16_t crc = 0xFFFFU;
  for (std::size_t index = 0; index < size; ++index) {
    crc ^= static_cast<std::uint16_t>(data[index]) << 8U;
    for (std::uint8_t bit = 0; bit < 8; ++bit) {
      crc = (crc & 0x8000U) != 0U
                ? static_cast<std::uint16_t>((crc << 1U) ^ 0x1021U)
                : static_cast<std::uint16_t>(crc << 1U);
    }
  }
  return crc;
}

ConfigurationPacket encodeConfiguration(const DspConfiguration& config) {
  ConfigurationPacket packet{};
  packet[0] = kProtocolVersion;
  packet[1] = static_cast<std::uint8_t>(config.delay_enabled ? 0x01U : 0U) |
              static_cast<std::uint8_t>(config.low_pass_enabled ? 0x02U : 0U) |
              static_cast<std::uint8_t>(config.bypass_all ? 0x04U : 0U) |
              static_cast<std::uint8_t>(config.bass_shelf.enabled ? 0x08U : 0U);
  writeU16(&packet[2], static_cast<std::uint16_t>(packet.size()));
  writeU32(&packet[4], config.revision);
  writeU32(&packet[8],
           static_cast<std::uint32_t>(std::lround(config.delay_ms * 1000.0F)));
  writeU16(&packet[12], static_cast<std::uint16_t>(
                            std::lround(config.low_pass_hz * 10.0F)));
  writeI16(&packet[14], static_cast<std::int16_t>(
                            std::lround(config.output_trim_db * 100.0F)));
  writeU16(&packet[16], static_cast<std::uint16_t>(
                            std::lround(config.bass_shelf.transition_hz * 10.0F)));
  writeI16(&packet[18], static_cast<std::int16_t>(
                            std::lround(config.bass_shelf.gain_db * 100.0F)));
  writeU16(&packet[20], crc16CcittFalse(packet.data(), 20));
  return packet;
}

PacketError decodeConfiguration(const std::uint8_t* data, std::size_t size,
                                DspConfiguration& output,
                                std::uint32_t minimum_revision) {
  if (size != kConfigurationPacketSize) {
    return PacketError::InvalidLength;
  }
  if (readU16(&data[2]) != size) {
    return PacketError::InvalidLength;
  }
  if (data[0] != kProtocolVersion) {
    return PacketError::UnsupportedVersion;
  }
  if ((data[1] & 0xF0U) != 0U) {
    return PacketError::ReservedFieldSet;
  }
  if (crc16CcittFalse(data, 20) != readU16(&data[20])) {
    return PacketError::InvalidCrc;
  }

  DspConfiguration decoded = DspConfiguration::defaults();
  decoded.revision = readU32(&data[4]);
  if (decoded.revision < minimum_revision) {
    return PacketError::StaleRevision;
  }
  decoded.delay_enabled = (data[1] & 0x01U) != 0U;
  decoded.low_pass_enabled = (data[1] & 0x02U) != 0U;
  decoded.bypass_all = (data[1] & 0x04U) != 0U;
  decoded.delay_ms = static_cast<float>(readU32(&data[8])) / 1000.0F;
  decoded.low_pass_hz = static_cast<float>(readU16(&data[12])) / 10.0F;
  decoded.output_trim_db = static_cast<float>(readI16(&data[14])) / 100.0F;
  decoded.bass_shelf.enabled = (data[1] & 0x08U) != 0U;
  decoded.bass_shelf.transition_hz =
      static_cast<float>(readU16(&data[16])) / 10.0F;
  decoded.bass_shelf.gain_db =
      static_cast<float>(readI16(&data[18])) / 100.0F;
  if (validateConfiguration(decoded) != ConfigurationError::None) {
    return PacketError::InvalidRange;
  }
  output = decoded;
  return PacketError::None;
}

TelemetryPacket encodeTelemetry(const AudioTelemetry& telemetry,
                                std::uint32_t configuration_revision,
                                bool codec_ready, bool audio_running,
                                bool settings_dirty) {
  TelemetryPacket packet{};
  packet[0] = kProtocolVersion;
  packet[1] = static_cast<std::uint8_t>(codec_ready ? 0x01U : 0U) |
              static_cast<std::uint8_t>(audio_running ? 0x02U : 0U) |
              static_cast<std::uint8_t>(telemetry.input_clipped ? 0x04U : 0U) |
              static_cast<std::uint8_t>(telemetry.output_clipped ? 0x08U : 0U) |
              static_cast<std::uint8_t>(telemetry.underrun_count > 0 ? 0x10U : 0U) |
              static_cast<std::uint8_t>(settings_dirty ? 0x20U : 0U);
  writeU16(&packet[2], static_cast<std::uint16_t>(packet.size()));
  writeU32(&packet[4], configuration_revision);
  writeI16(&packet[8], amplitudeToCentiDb(telemetry.input_peak[0]));
  writeI16(&packet[10], amplitudeToCentiDb(telemetry.input_peak[1]));
  writeI16(&packet[12], amplitudeToCentiDb(telemetry.output_peak[0]));
  writeI16(&packet[14], amplitudeToCentiDb(telemetry.output_peak[1]));
  writeU32(&packet[16], telemetry.underrun_count);
  return packet;
}

PacketError decodeCommand(const std::uint8_t* data, std::size_t size,
                          DecodedCommand& output) {
  if (size != kCommandPacketSize || readU16(&data[2]) != size) {
    return PacketError::InvalidLength;
  }
  if (data[0] != kProtocolVersion) {
    return PacketError::UnsupportedVersion;
  }
  if (data[1] < static_cast<std::uint8_t>(CommandOpcode::Save) ||
      data[1] > static_cast<std::uint8_t>(CommandOpcode::ClearClip)) {
    return PacketError::InvalidRange;
  }
  output.opcode = static_cast<CommandOpcode>(data[1]);
  output.request_id = readU32(&data[4]);
  return PacketError::None;
}

CommandPacket encodeCommandStatus(CommandStatus status,
                                  std::uint32_t request_id) {
  CommandPacket packet{};
  packet[0] = kProtocolVersion;
  packet[1] = static_cast<std::uint8_t>(status);
  writeU16(&packet[2], static_cast<std::uint16_t>(packet.size()));
  writeU32(&packet[4], request_id);
  return packet;
}

}  // namespace audiocontrol::wire
