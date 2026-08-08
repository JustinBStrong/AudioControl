#include <Arduino.h>
#include <BLE2902.h>
#include <BLEDevice.h>
#include <BLEServer.h>
#include <Preferences.h>
#include <Wire.h>

#ifdef AUDIOCONTROL_ADC_CAPTURE
#include <SPIFFS.h>
#endif

#include <algorithm>
#include <array>
#include <cstdint>
#include <cstring>

#include "AudioTools.h"
#include "AudioTools/AudioLibs/AudioBoardStream.h"
#include "audiocontrol/dsp_engine.hpp"
#include "audiocontrol/wire_protocol.hpp"

namespace {

using audiocontrol::DspConfiguration;
using audiocontrol::DspEngine;
using audiocontrol::StereoFrame;
using audiocontrol::wire::CommandOpcode;
using audiocontrol::wire::CommandStatus;
using audiocontrol::wire::DecodedCommand;
using audiocontrol::wire::PacketError;

constexpr char kDeviceName[] = "AudioControl";
constexpr char kPreferencesNamespace[] = "audioctl";
constexpr char kConfigurationKey[] = "config-v2";
// Keep I2S DMA service activity above the subwoofer passband. The library's
// 512-frame default makes the ESP32 refill TX DMA at 93.75 Hz, which couples a
// measurable tone into the ES8388 ADC on this board. Eight-frame blocks move
// that transport cadence to 6 kHz without changing any PCM sample value.
constexpr std::size_t kAudioBlockFrames = 8;
// Match telemetry to the quiet BLE connection cadence. Publishing at 200 ms
// queues multiple notifications per radio event and can starve configuration
// reads/writes when the one-second interval is active.
constexpr unsigned long kTelemetryIntervalMs = 1000;
constexpr unsigned long kPersistenceQuietPeriodMs = 2000;

#ifdef AUDIOCONTROL_ADC_CAPTURE
constexpr std::uint32_t kCaptureSampleRate = 48000;
constexpr std::size_t kCaptureChannels = 2;
constexpr std::size_t kCaptureDecimation = 1;
// Preserve both codec channels at the native sample rate. Channel averaging
// can hide differential interference, so the diagnostic stream must remain
// stereo even though the production subwoofer path will eventually sum them.
#ifdef AUDIOCONTROL_CAPTURE_ENABLE_BLE
// BLE and the 250 ms stereo delay line also require internal RAM. A short
// stereo window is enough to verify whether radio activity adds interference.
constexpr std::size_t kCaptureFrames = 4000;
#else
constexpr std::size_t kCaptureFrames = 12000;
#endif
constexpr char kCaptureArmKey[] = "cap-armed";
constexpr char kCaptureFile[] = "/adc-capture.pcm";
constexpr unsigned long kOfflineCaptureDelayMs = 5000;
#endif

// AudioKitEs8388V1 is the official Ai-Thinker wiring. The V2 driver profile is
// an alternate clone wiring; it does not mean PCB revision V2.2.
audio_tools::AudioBoardStream official_audio(
    audio_driver::AudioKitEs8388V1);
audio_tools::AudioBoardStream alternate_audio(
    audio_driver::AudioKitEs8388V2);
audio_tools::AudioBoardStream* audio = nullptr;

DspEngine engine;
Preferences preferences;
BLECharacteristic* configuration_characteristic = nullptr;
BLECharacteristic* telemetry_characteristic = nullptr;
BLECharacteristic* command_characteristic = nullptr;

portMUX_TYPE control_mux = portMUX_INITIALIZER_UNLOCKED;
DspConfiguration pending_configuration{};
DecodedCommand pending_command{};
volatile bool has_pending_configuration = false;
volatile bool has_pending_command = false;
volatile std::uint32_t active_revision = 0;

bool codec_ready = false;
bool audio_running = false;
volatile bool ble_connected = false;
bool settings_dirty = false;
unsigned long last_configuration_change_ms = 0;
unsigned long last_telemetry_ms = 0;

std::array<std::int16_t, kAudioBlockFrames * 2> pcm{};
std::array<StereoFrame, kAudioBlockFrames> input_frames{};
std::array<StereoFrame, kAudioBlockFrames> output_frames{};
std::array<float, 2> input_peak_accumulator{0.0F, 0.0F};
std::array<float, 2> output_peak_accumulator{0.0F, 0.0F};

#ifdef AUDIOCONTROL_ADC_CAPTURE
std::array<std::int16_t, kCaptureFrames * kCaptureChannels> capture_pcm{};
bool capture_active = false;
bool capture_ready = false;
std::size_t capture_frame_count = 0;
std::size_t capture_decimation_count = 0;
std::int32_t capture_left_sum = 0;
std::int32_t capture_right_sum = 0;
bool offline_capture_scheduled = false;
bool capture_to_flash = false;
unsigned long offline_capture_start_ms = 0;

void startCapture(bool save_to_flash) {
  capture_frame_count = 0;
  capture_decimation_count = 0;
  capture_left_sum = 0;
  capture_right_sum = 0;
  capture_to_flash = save_to_flash;
  capture_active = true;
}

void transmitCaptureBytes(const std::uint8_t* bytes, std::size_t byte_count) {
  Serial.printf("CAPTURE_BEGIN %u %u %u %u\n",
                static_cast<unsigned>(kCaptureSampleRate),
                static_cast<unsigned>(kCaptureChannels),
                static_cast<unsigned>(kCaptureFrames),
                static_cast<unsigned>(byte_count));
  Serial.flush();
  constexpr std::size_t kChunkBytes = 256;
  for (std::size_t offset = 0; offset < byte_count; offset += kChunkBytes) {
    const std::size_t remaining = byte_count - offset;
    Serial.write(bytes + offset, std::min(kChunkBytes, remaining));
  }
  Serial.flush();
  Serial.print("\nCAPTURE_END\n");
  Serial.flush();
}

void transmitStoredCapture() {
  auto file = SPIFFS.open(kCaptureFile, FILE_READ);
  const std::size_t expected_bytes = capture_pcm.size() * sizeof(std::int16_t);
  if (!file || file.size() != expected_bytes) {
    Serial.println("ERROR_NO_STORED_CAPTURE");
    if (file) {
      file.close();
    }
    return;
  }
  const std::size_t read_bytes = file.read(
      reinterpret_cast<std::uint8_t*>(capture_pcm.data()), expected_bytes);
  file.close();
  if (read_bytes != expected_bytes) {
    Serial.println("ERROR_STORED_CAPTURE_READ");
    return;
  }
  transmitCaptureBytes(
      reinterpret_cast<const std::uint8_t*>(capture_pcm.data()),
      expected_bytes);
}

void pollCaptureCommand() {
  while (Serial.available() > 0) {
    const int command = Serial.read();
    if (command == 'A' && !capture_active && !capture_ready) {
      if (preferences.putBool(kCaptureArmKey, true)) {
        Serial.println("OFFLINE_CAPTURE_ARMED");
      } else {
        Serial.println("ERROR_OFFLINE_ARM");
      }
      Serial.flush();
      continue;
    }
    if (command == 'D' && !capture_active && !capture_ready) {
      transmitStoredCapture();
      continue;
    }
    if (command != 'R' || capture_active || capture_ready) {
      continue;
    }
    startCapture(false);
    Serial.printf("CAPTURE_ARMED %u %u %u\n",
                  static_cast<unsigned>(kCaptureSampleRate),
                  static_cast<unsigned>(kCaptureChannels),
                  static_cast<unsigned>(kCaptureFrames));
  }
}

void captureStereoSample(std::int32_t left, std::int32_t right) {
  if (!capture_active) {
    return;
  }
  capture_left_sum += left;
  capture_right_sum += right;
  ++capture_decimation_count;
  if (capture_decimation_count != kCaptureDecimation) {
    return;
  }
  capture_pcm[capture_frame_count * 2U] = static_cast<std::int16_t>(
      capture_left_sum / static_cast<std::int32_t>(kCaptureDecimation));
  capture_pcm[capture_frame_count * 2U + 1U] = static_cast<std::int16_t>(
      capture_right_sum / static_cast<std::int32_t>(kCaptureDecimation));
  ++capture_frame_count;
  capture_decimation_count = 0;
  capture_left_sum = 0;
  capture_right_sum = 0;
  if (capture_frame_count == kCaptureFrames) {
    capture_active = false;
    capture_ready = true;
  }
}

void captureInputFrames(std::size_t frame_count) {
  for (std::size_t index = 0; index < frame_count && capture_active; ++index) {
    captureStereoSample(pcm[index * 2U], pcm[index * 2U + 1U]);
  }
}

void captureOutputFrames(std::size_t frame_count) {
  for (std::size_t index = 0; index < frame_count && capture_active; ++index) {
    const auto left = static_cast<std::int32_t>(std::lround(
        std::clamp(output_frames[index].left, -1.0F, 1.0F) * 32767.0F));
    const auto right = static_cast<std::int32_t>(std::lround(
        std::clamp(output_frames[index].right, -1.0F, 1.0F) * 32767.0F));
    captureStereoSample(left, right);
  }
}

void transmitCaptureIfReady() {
  if (!capture_ready) {
    return;
  }
  const std::size_t byte_count = capture_pcm.size() * sizeof(std::int16_t);
  if (capture_to_flash) {
    auto file = SPIFFS.open(kCaptureFile, FILE_WRITE);
    if (!file) {
      Serial.println("ERROR_OFFLINE_CAPTURE_OPEN");
    } else {
      const std::size_t written = file.write(
          reinterpret_cast<const std::uint8_t*>(capture_pcm.data()),
          byte_count);
      file.close();
      Serial.println(written == byte_count ? "OFFLINE_CAPTURE_SAVED"
                                           : "ERROR_OFFLINE_CAPTURE_WRITE");
    }
  } else {
    transmitCaptureBytes(
        reinterpret_cast<const std::uint8_t*>(capture_pcm.data()), byte_count);
  }
  capture_to_flash = false;
  capture_ready = false;
}

void beginScheduledOfflineCaptureIfDue() {
  if (!offline_capture_scheduled || capture_active || capture_ready ||
      millis() < offline_capture_start_ms) {
    return;
  }
  offline_capture_scheduled = false;
  startCapture(true);
  Serial.println("OFFLINE_CAPTURE_RECORDING");
}
#endif

CommandStatus statusForPacketError(PacketError error) {
  switch (error) {
    case PacketError::None:
      return CommandStatus::Ok;
    case PacketError::UnsupportedVersion:
      return CommandStatus::Version;
    case PacketError::InvalidLength:
      return CommandStatus::Length;
    case PacketError::InvalidCrc:
      return CommandStatus::Crc;
    case PacketError::InvalidRange:
      return CommandStatus::Range;
    case PacketError::ReservedFieldSet:
      return CommandStatus::Reserved;
    case PacketError::StaleRevision:
      return CommandStatus::StaleRevision;
  }
  return CommandStatus::Internal;
}

void notifyStatus(CommandStatus status, std::uint32_t request_id) {
  if (command_characteristic == nullptr) {
    return;
  }
  auto packet = audiocontrol::wire::encodeCommandStatus(status, request_id);
  command_characteristic->setValue(packet.data(), packet.size());
  command_characteristic->notify();
}

bool probeCodec(int sda, int scl) {
  Wire.end();
  if (!Wire.begin(sda, scl, 100000U)) {
    return false;
  }
  Wire.beginTransmission(0x10);
  return Wire.endTransmission() == 0;
}

bool beginAudioHardware() {
  if (probeCodec(33, 32)) {
    Serial.println("ES8388 found on official profile SDA33/SCL32");
    audio = &official_audio;
  } else if (probeCodec(18, 23)) {
    Serial.println("ES8388 found on alternate profile SDA18/SCL23");
    audio = &alternate_audio;
  } else {
    Serial.println("ERROR: ES8388 not found at I2C address 0x10");
    return false;
  }

#ifdef AUDIOCONTROL_CAPTURE_INPUT_ONLY
  auto config = audio->defaultConfig(RX_MODE);
#else
  auto config = audio->defaultConfig(RXTX_MODE);
#endif
  config.sample_rate = 48000;
  config.channels = 2;
  config.bits_per_sample = 16;
  config.buffer_size = 8;
  // Ai-Thinker's ES8388 ESP32-A1S maps the board's LINEINL/LINEINR pins to
  // LIN2/RIN2. Some V2.2 module revisions also electrically mix the onboard
  // microphone wiring into this pair; LINE1 does not receive the LINEIN jack.
  config.input_device = ADC_INPUT_LINE2;
#ifndef AUDIOCONTROL_CAPTURE_INPUT_ONLY
  config.output_device = DAC_OUTPUT_LINE1;
#endif
  config.sd_active = false;
  if (!audio->begin(config)) {
    Serial.println("ERROR: ES8388/I2S initialization failed");
    return false;
  }
  audio->setPAPower(false);
  audio->setInputVolume(0.0F);
  audio->setVolume(1.0F);
  return true;
}

bool persistConfiguration() {
  const auto packet =
      audiocontrol::wire::encodeConfiguration(engine.configuration());
  const std::size_t written =
      preferences.putBytes(kConfigurationKey, packet.data(), packet.size());
  if (written != packet.size()) {
    Serial.println("ERROR: failed to persist complete configuration");
    return false;
  }
  settings_dirty = false;
  return true;
}

void loadConfiguration() {
  auto config = DspConfiguration::defaults();
  config.revision = 1;
  if (preferences.getBytesLength(kConfigurationKey) ==
      audiocontrol::wire::kConfigurationPacketSize) {
    audiocontrol::wire::ConfigurationPacket packet{};
    preferences.getBytes(kConfigurationKey, packet.data(), packet.size());
    DspConfiguration saved;
    if (audiocontrol::wire::decodeConfiguration(
            packet.data(), packet.size(), saved) == PacketError::None) {
      config = saved;
      Serial.println("Loaded saved DSP configuration");
    } else {
      Serial.println("Saved configuration invalid; using defaults");
    }
  }
  engine.applyConfiguration(config);
  active_revision = config.revision;
}

class ConfigurationCallbacks final : public BLECharacteristicCallbacks {
  void onWrite(BLECharacteristic* characteristic) override {
    const auto value = characteristic->getValue();
    DspConfiguration decoded;
    std::uint32_t minimum_revision;
    portENTER_CRITICAL(&control_mux);
    minimum_revision = active_revision == UINT32_MAX ? UINT32_MAX
                                                     : active_revision + 1U;
    portEXIT_CRITICAL(&control_mux);
    const auto error = audiocontrol::wire::decodeConfiguration(
        reinterpret_cast<const std::uint8_t*>(value.c_str()), value.size(),
        decoded, minimum_revision);
    if (error != PacketError::None) {
      std::uint32_t request_id = 0;
      if (value.size() >= 8U) {
        const auto* bytes = reinterpret_cast<const std::uint8_t*>(value.c_str());
        request_id = static_cast<std::uint32_t>(bytes[4]) |
                     static_cast<std::uint32_t>(bytes[5]) << 8U |
                     static_cast<std::uint32_t>(bytes[6]) << 16U |
                     static_cast<std::uint32_t>(bytes[7]) << 24U;
      }
      notifyStatus(statusForPacketError(error), request_id);
      return;
    }
    portENTER_CRITICAL(&control_mux);
    pending_configuration = decoded;
    has_pending_configuration = true;
    portEXIT_CRITICAL(&control_mux);
  }
};

class CommandCallbacks final : public BLECharacteristicCallbacks {
  void onWrite(BLECharacteristic* characteristic) override {
    const auto value = characteristic->getValue();
    DecodedCommand decoded;
    const auto error = audiocontrol::wire::decodeCommand(
        reinterpret_cast<const std::uint8_t*>(value.c_str()), value.size(),
        decoded);
    if (error != PacketError::None) {
      notifyStatus(statusForPacketError(error), 0);
      return;
    }
    portENTER_CRITICAL(&control_mux);
    pending_command = decoded;
    has_pending_command = true;
    portEXIT_CRITICAL(&control_mux);
  }
};

class ServerCallbacks final : public BLEServerCallbacks {
  void onConnect(BLEServer*) override { ble_connected = true; }

  void onConnect(BLEServer* server, esp_ble_gatts_cb_param_t* parameters) override {
    // Configuration is low-bandwidth. A one-second connection interval avoids
    // the 20-80 ms radio cadence coupling into the codec while still making a
    // slider update feel immediate enough for set-and-forget tuning.
    server->updateConnParams(parameters->connect.remote_bda, 800, 800, 0, 600);
  }

  void onDisconnect(BLEServer*) override {
    ble_connected = false;
    BLEDevice::startAdvertising();
  }
};

void beginBle() {
  BLEDevice::init(kDeviceName);
  BLEDevice::setMTU(64);
  auto* server = BLEDevice::createServer();
  server->setCallbacks(new ServerCallbacks());
  auto* service = server->createService(audiocontrol::wire::kServiceUuid);

  configuration_characteristic = service->createCharacteristic(
      audiocontrol::wire::kConfigurationUuid,
      BLECharacteristic::PROPERTY_READ | BLECharacteristic::PROPERTY_WRITE |
          BLECharacteristic::PROPERTY_NOTIFY);
  telemetry_characteristic = service->createCharacteristic(
      audiocontrol::wire::kTelemetryUuid,
      BLECharacteristic::PROPERTY_READ | BLECharacteristic::PROPERTY_NOTIFY);
  command_characteristic = service->createCharacteristic(
      audiocontrol::wire::kCommandUuid,
      BLECharacteristic::PROPERTY_WRITE | BLECharacteristic::PROPERTY_NOTIFY);
  configuration_characteristic->addDescriptor(new BLE2902());
  telemetry_characteristic->addDescriptor(new BLE2902());
  command_characteristic->addDescriptor(new BLE2902());
  configuration_characteristic->setCallbacks(new ConfigurationCallbacks());
  command_characteristic->setCallbacks(new CommandCallbacks());

  auto config_packet =
      audiocontrol::wire::encodeConfiguration(engine.configuration());
  configuration_characteristic->setValue(config_packet.data(),
                                           config_packet.size());
  auto telemetry_packet = audiocontrol::wire::encodeTelemetry(
      engine.telemetry(), active_revision, codec_ready, audio_running,
      settings_dirty);
  telemetry_characteristic->setValue(telemetry_packet.data(),
                                      telemetry_packet.size());

  service->start();
  auto* advertising = BLEDevice::getAdvertising();
  advertising->addServiceUUID(audiocontrol::wire::kServiceUuid);
  advertising->setScanResponse(true);
  // The Arduino BLE default advertises every 20-40 ms. On this compact board,
  // those RF/current bursts measurably couple into the left codec input. One
  // advertisement per second remains easy to discover for a set-and-forget
  // controller while cutting idle radio activity by more than 25x.
  advertising->setMinInterval(1600);
  advertising->setMaxInterval(1600);
  advertising->setMinPreferred(800);
  advertising->setMaxPreferred(800);
  advertising->start();
}

void applyPendingControls() {
  DspConfiguration config;
  bool apply_config = false;
  DecodedCommand command;
  bool apply_command = false;
  portENTER_CRITICAL(&control_mux);
  if (has_pending_configuration) {
    config = pending_configuration;
    has_pending_configuration = false;
    apply_config = true;
  }
  if (has_pending_command) {
    command = pending_command;
    has_pending_command = false;
    apply_command = true;
  }
  portEXIT_CRITICAL(&control_mux);

  if (apply_config) {
    const auto error = engine.applyConfiguration(config);
    if (error == audiocontrol::ConfigurationError::None) {
      active_revision = config.revision;
      settings_dirty = true;
      last_configuration_change_ms = millis();
      auto packet = audiocontrol::wire::encodeConfiguration(config);
      configuration_characteristic->setValue(packet.data(), packet.size());
      configuration_characteristic->notify();
      notifyStatus(CommandStatus::Ok, config.revision);
    } else {
      notifyStatus(CommandStatus::Range, config.revision);
    }
  }

  if (!apply_command) {
    return;
  }
  switch (command.opcode) {
    case CommandOpcode::Save:
      notifyStatus(persistConfiguration() ? CommandStatus::Ok
                                          : CommandStatus::Internal,
                   command.request_id);
      break;
    case CommandOpcode::RestoreDefaults: {
      auto defaults = DspConfiguration::defaults();
      defaults.revision = active_revision + 1U;
      engine.applyConfiguration(defaults);
      active_revision = defaults.revision;
      settings_dirty = true;
      last_configuration_change_ms = millis();
      auto packet = audiocontrol::wire::encodeConfiguration(defaults);
      configuration_characteristic->setValue(packet.data(), packet.size());
      configuration_characteristic->notify();
      notifyStatus(CommandStatus::Ok, command.request_id);
      break;
    }
    case CommandOpcode::ClearClip:
      engine.clearClipLatches();
      engine.clearUnderruns();
      notifyStatus(CommandStatus::Ok, command.request_id);
      break;
    case CommandOpcode::Reboot:
      persistConfiguration();
      notifyStatus(CommandStatus::Ok, command.request_id);
      delay(50);
      ESP.restart();
      break;
  }
}

void publishTelemetryIfDue() {
  const auto now = millis();
  if (now - last_telemetry_ms < kTelemetryIntervalMs) {
    return;
  }
  last_telemetry_ms = now;
  auto telemetry = engine.telemetry();
  telemetry.input_peak = input_peak_accumulator;
  telemetry.output_peak = output_peak_accumulator;
  input_peak_accumulator = {0.0F, 0.0F};
  output_peak_accumulator = {0.0F, 0.0F};
  auto packet = audiocontrol::wire::encodeTelemetry(
      telemetry, active_revision, codec_ready, audio_running, settings_dirty);
  telemetry_characteristic->setValue(packet.data(), packet.size());
  if (ble_connected) {
    telemetry_characteristic->notify();
  }
}

void processAudioBlock() {
  if (!audio_running) {
    delay(5);
    return;
  }
  const std::size_t requested_bytes = pcm.size() * sizeof(std::int16_t);
  const std::size_t received_bytes = audio->readBytes(
      reinterpret_cast<std::uint8_t*>(pcm.data()), requested_bytes);
  const std::size_t frame_count =
      std::min(kAudioBlockFrames, received_bytes / (2U * sizeof(std::int16_t)));
  if (frame_count == 0) {
    engine.incrementUnderruns();
    return;
  }
  if (received_bytes != requested_bytes) {
    engine.incrementUnderruns();
  }
  for (std::size_t index = 0; index < frame_count; ++index) {
    input_frames[index].left = static_cast<float>(pcm[index * 2U]) / 32768.0F;
    input_frames[index].right =
        static_cast<float>(pcm[index * 2U + 1U]) / 32768.0F;
  }
#ifdef AUDIOCONTROL_ADC_CAPTURE
#ifndef AUDIOCONTROL_CAPTURE_OUTPUT
  captureInputFrames(frame_count);
#endif
#endif
#ifdef AUDIOCONTROL_CAPTURE_INPUT_ONLY
  return;
#endif
  engine.process(input_frames.data(), output_frames.data(), frame_count);
#ifdef AUDIOCONTROL_CAPTURE_OUTPUT
  captureOutputFrames(frame_count);
#endif
  const auto& telemetry = engine.telemetry();
  for (std::size_t channel = 0; channel < 2; ++channel) {
    input_peak_accumulator[channel] = std::max(
        input_peak_accumulator[channel], telemetry.input_peak[channel]);
    output_peak_accumulator[channel] = std::max(
        output_peak_accumulator[channel], telemetry.output_peak[channel]);
  }
  for (std::size_t index = 0; index < frame_count; ++index) {
    pcm[index * 2U] = static_cast<std::int16_t>(
        std::lround(output_frames[index].left * 32767.0F));
    pcm[index * 2U + 1U] = static_cast<std::int16_t>(
        std::lround(output_frames[index].right * 32767.0F));
  }
  const std::size_t output_bytes = frame_count * 2U * sizeof(std::int16_t);
  if (audio->write(reinterpret_cast<const std::uint8_t*>(pcm.data()),
                   output_bytes) != output_bytes) {
    engine.incrementUnderruns();
  }
}

}  // namespace

void setup() {
  Serial.begin(115200);
  delay(100);
  AudioToolsLogger.begin(Serial, AudioToolsLogLevel::Warning);
  AudioDriverLogger.begin(Serial, AudioDriverLogLevel::Warning);
  preferences.begin(kPreferencesNamespace, false);
  loadConfiguration();
  codec_ready = beginAudioHardware();
  audio_running = codec_ready;
#ifndef AUDIOCONTROL_ADC_CAPTURE
  beginBle();
  Serial.println(codec_ready ? "AudioControl ready" :
                               "AudioControl BLE ready; audio hardware unavailable");
#else
  if (!SPIFFS.begin(true)) {
    Serial.println("ERROR: SPIFFS initialization failed");
  }
#ifdef AUDIOCONTROL_CAPTURE_ENABLE_BLE
  beginBle();
#endif
  if (preferences.getBool(kCaptureArmKey, false)) {
    preferences.putBool(kCaptureArmKey, false);
    offline_capture_scheduled = true;
    offline_capture_start_ms = millis() + kOfflineCaptureDelayMs;
    Serial.println("Offline ADC capture scheduled in 5 seconds");
  }
  Serial.println(codec_ready ? "AudioControl ADC capture ready" :
                               "AudioControl ADC capture hardware unavailable");
#endif
}

void loop() {
#ifdef AUDIOCONTROL_ADC_CAPTURE
  pollCaptureCommand();
  beginScheduledOfflineCaptureIfDue();
  processAudioBlock();
  transmitCaptureIfReady();
#else
  processAudioBlock();
  applyPendingControls();
  publishTelemetryIfDue();
  if (settings_dirty &&
      millis() - last_configuration_change_ms >=
          kPersistenceQuietPeriodMs) {
    persistConfiguration();
  }
#endif
}
