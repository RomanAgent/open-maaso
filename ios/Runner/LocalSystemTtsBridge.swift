import AVFoundation
import Flutter
import Foundation

/// Request-scoped local synthesis. The generated PCM uses the existing Dart
/// audio player and its correlated start/completion and lip-sync lifecycle.
final class LocalSystemTtsBridge {
  private final class Job {
    let id: String
    let synth = AVSpeechSynthesizer()
    var result: FlutterResult?
    var pcm = Data()
    var sampleRate: Double = 0
    init(id: String, result: @escaping FlutterResult) {
      self.id = id
      self.result = result
    }
  }

  private let channel: FlutterMethodChannel
  private var active: Job?
  private let maximumBytes = 20 * 1024 * 1024 - 44

  init(channel: FlutterMethodChannel) {
    self.channel = channel
    channel.setMethodCallHandler { [weak self] call, result in
      guard let self = self else {
        result(FlutterError(code: "system_tts_closed", message: "System speech is unavailable.", details: nil))
        return
      }
      switch call.method {
      case "isAvailable":
        result(!AVSpeechSynthesisVoice.speechVoices().isEmpty)
      case "synthesize":
        self.synthesize(call.arguments, result)
      case "cancel":
        let args = call.arguments as? [String: Any]
        guard let job = self.active, args?["id"] as? String == job.id else {
          result(false)
          return
        }
        self.fail(job, "system_tts_cancelled")
        result(true)
      default:
        result(FlutterMethodNotImplemented)
      }
    }
  }

  private func synthesize(_ arguments: Any?, _ result: @escaping FlutterResult) {
    guard let args = arguments as? [String: Any],
          let id = args["id"] as? String, !id.isEmpty, id.count <= 128,
          let text = args["text"] as? String, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
          text.utf16.count <= 8000 else {
      result(FlutterError(code: "system_tts_input", message: "Invalid system speech request.", details: nil))
      return
    }
    guard active == nil else {
      result(FlutterError(code: "system_tts_busy", message: "System speech is busy.", details: nil))
      return
    }
    let language = (args["language"] as? String ?? "en").replacingOccurrences(of: "_", with: "-")
    let prefix = language.lowercased().split(separator: "-").first.map(String.init) ?? "en"
    let voices = AVSpeechSynthesisVoice.speechVoices().filter {
      $0.language.lowercased().split(separator: "-").first.map(String.init) == prefix
    }.sorted {
      let leftExact = $0.language.caseInsensitiveCompare(language) == .orderedSame
      let rightExact = $1.language.caseInsensitiveCompare(language) == .orderedSame
      if leftExact != rightExact { return leftExact }
      return $0.quality.rawValue < $1.quality.rawValue
    }
    guard let voice = voices.first else {
      result(FlutterError(code: "system_tts_voice_missing", message: "No installed voice is available for this language.", details: nil))
      return
    }
    let job = Job(id: id, result: result)
    active = job
    let utterance = AVSpeechUtterance(string: text)
    utterance.voice = voice
    utterance.rate = AVSpeechUtteranceDefaultSpeechRate
    utterance.pitchMultiplier = 1.0
    utterance.volume = 1.0
    // AVSpeechSynthesizer.write uses the enumerated installed voice. No remote
    // service, voice download or global flutter_tts completion callback is used.
    job.synth.write(utterance) { [weak self, weak job] buffer in
      guard let self = self, let job = job, let pcm = buffer as? AVAudioPCMBuffer else { return }
      let frames = Int(pcm.frameLength)
      let rate = pcm.format.sampleRate
      let chunk = frames == 0 ? Data() : Self.monoInt16(pcm)
      DispatchQueue.main.async {
        guard self.active === job else { return }
        if frames == 0 {
          guard !job.pcm.isEmpty, job.sampleRate > 0 else {
            self.fail(job, "system_tts_empty_audio")
            return
          }
          let bytes = Self.wav(job.pcm, UInt32(job.sampleRate.rounded()))
          let callback = job.result
          job.result = nil
          self.active = nil
          callback?(FlutterStandardTypedData(bytes: bytes))
          return
        }
        guard let chunk = chunk, rate.isFinite, rate >= 8000, rate <= 192000,
              (job.sampleRate == 0 || abs(job.sampleRate - rate) < 0.5),
              job.pcm.count + chunk.count <= self.maximumBytes else {
          self.fail(job, "system_tts_audio_format")
          return
        }
        job.sampleRate = rate
        job.pcm.append(chunk)
      }
    }
    DispatchQueue.main.asyncAfter(deadline: .now() + 29) { [weak self, weak job] in
      guard let self = self, let job = job, self.active === job else { return }
      self.fail(job, "system_tts_timeout")
    }
  }

  private func fail(_ job: Job, _ code: String) {
    guard active === job else { return }
    active = nil
    let callback = job.result
    job.result = nil
    job.synth.stopSpeaking(at: .immediate)
    job.pcm.removeAll()
    callback?(FlutterError(code: code, message: "Local system speech did not complete.", details: nil))
  }

  private static func monoInt16(_ buffer: AVAudioPCMBuffer) -> Data? {
    let channels = Int(buffer.format.channelCount)
    guard channels > 0, channels <= 8 else { return nil }
    let interleaved = buffer.format.isInterleaved
    var result = Data(capacity: Int(buffer.frameLength) * 2)
    for frame in 0..<Int(buffer.frameLength) {
      var value: Float = 0
      for channel in 0..<channels {
        let index = interleaved ? frame * channels + channel : frame
        let plane = interleaved ? 0 : channel
        if let data = buffer.floatChannelData { value += data[plane][index] }
        else if let data = buffer.int16ChannelData { value += Float(data[plane][index]) / 32768 }
        else { return nil }
      }
      value /= Float(channels)
      guard value.isFinite else { return nil }
      var sample = Int16((max(-1, min(1, value)) * 32767).rounded()).littleEndian
      withUnsafeBytes(of: &sample) { result.append(contentsOf: $0) }
    }
    return result
  }

  private static func wav(_ pcm: Data, _ rate: UInt32) -> Data {
    var data = Data("RIFF".utf8)
    func u32(_ value: UInt32) { var v = value.littleEndian; withUnsafeBytes(of: &v) { data.append(contentsOf: $0) } }
    func u16(_ value: UInt16) { var v = value.littleEndian; withUnsafeBytes(of: &v) { data.append(contentsOf: $0) } }
    u32(UInt32(pcm.count) + 36)
    data.append(Data("WAVEfmt ".utf8))
    u32(16); u16(1); u16(1); u32(rate); u32(rate * 2); u16(2); u16(16)
    data.append(Data("data".utf8)); u32(UInt32(pcm.count)); data.append(pcm)
    return data
  }
}
