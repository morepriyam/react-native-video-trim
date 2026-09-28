import AVFoundation
import CoreMedia
import CoreVideo

// MARK: - Native conform engine (AVFoundation)
//
// Re-encodes a clip into an exact target signature — coded size + rotation tag, frame rate,
// H.264, 8-bit BT.709 SDR, AAC at a given rate/channel count — on the platform media stack:
// hardware decode, GPU scale/letterbox/rotate (AVVideoComposition), hardware encode. Compared
// with the FFmpeg path this is several times faster on-device (no software HEVC decode, no CPU
// scaling), tone-maps HDR (HLG, PQ, Dolby Vision) to SDR with Apple's own mapper instead of
// just re-tagging it, and reads only the audio track the platform plays by default (never an
// undecodable Spatial Audio APAC companion track).
//
// The output can carry a rotation tag: the canvas is the DISPLAY size, and with a 90/270
// rotation the pixels are written in the rotated coded orientation plus the matching track
// transform — exactly how camera recorders write portrait video. That is what lets an import
// share a camera recording's copy-compatibility signature, so a merge joins them with no
// re-encode at all.
//
// Throws (via the completion) when AVFoundation can't read the source or the write fails;
// callers fall back to the FFmpeg path for formats outside the platform's decoders.
public final class NativeConform {
  public struct Target {
    /// Display (post-rotation) canvas; the source is scale-fit and centered on it.
    public var canvasWidth: Int
    public var canvasHeight: Int
    /// Output display rotation in probeVideo's convention (FFprobe display-matrix degrees,
    /// normalized to 0...359): a camera-app portrait clip probes 270, a clip whose matrix
    /// is the opposite quarter turn probes 90.
    public var rotation: Int
    public var frameRate: Int
    public var bitrate: Int
    /// Target audio format; <= 0 keeps the source's (rate capped at 48 kHz, channels at 2
    /// unless the source is 5.1).
    public var audioSampleRate: Int
    public var audioChannels: Int
    /// Keep the video samples untouched (no decode) and only conform the audio.
    public var copyVideo: Bool

    public init(canvasWidth: Int, canvasHeight: Int, rotation: Int, frameRate: Int, bitrate: Int,
                audioSampleRate: Int, audioChannels: Int, copyVideo: Bool) {
      self.canvasWidth = canvasWidth
      self.canvasHeight = canvasHeight
      self.rotation = rotation
      self.frameRate = frameRate
      self.bitrate = bitrate
      self.audioSampleRate = audioSampleRate
      self.audioChannels = audioChannels
      self.copyVideo = copyVideo
    }
  }

  public struct ConformError: LocalizedError {
    public let stage: String
    public let message: String
    public var errorDescription: String? { "\(stage): \(message)" }
  }

  private let reader: AVAssetReader
  private let writer: AVAssetWriter
  private let pairs: [(AVAssetReaderOutput, AVAssetWriterInput)]
  /// Set for a video re-encode: frames are appended through it at exact 1/fps ticks.
  private let cfr: (adaptor: AVAssetWriterInputPixelBufferAdaptor, fps: Int32)?
  private let duration: CMTime
  private let progress: ((Double) -> Void)?
  private let lock = NSLock()
  private var cancelled = false

  private init(reader: AVAssetReader, writer: AVAssetWriter, pairs: [(AVAssetReaderOutput, AVAssetWriterInput)],
               cfr: (adaptor: AVAssetWriterInputPixelBufferAdaptor, fps: Int32)?,
               duration: CMTime, progress: ((Double) -> Void)?) {
    self.reader = reader
    self.writer = writer
    self.pairs = pairs
    self.cfr = cfr
    self.duration = duration
    self.progress = progress
  }

  // MARK: Public entry

  /// Conform `source` into `output` (overwritten). Completion fires once on a background queue.
  /// Returns the running job (for `cancel()`), or nil when setup already failed.
  @discardableResult
  public static func run(source: URL, output: URL, target: Target,
                         progress: ((Double) -> Void)? = nil,
                         completion: @escaping (Result<URL, ConformError>) -> Void) -> NativeConform? {
    let job: NativeConform
    do {
      job = try prepare(source: source, output: output, target: target, progress: progress)
    } catch let e as ConformError {
      completion(.failure(e))
      return nil
    } catch {
      completion(.failure(ConformError(stage: "prepare", message: error.localizedDescription)))
      return nil
    }
    job.start(output: output, completion: completion)
    return job
  }

  // MARK: Setup

  private static func prepare(source: URL, output: URL, target: Target,
                              progress: ((Double) -> Void)?) throws -> NativeConform {
    let asset = AVURLAsset(url: source, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
    guard asset.isReadable else {
      throw ConformError(stage: "open", message: "AVFoundation can't read this file")
    }
    guard let vtrack = asset.tracks(withMediaType: .video).first(where: { $0.isEnabled })
            ?? asset.tracks(withMediaType: .video).first else {
      throw ConformError(stage: "open", message: "no video track")
    }
    let natural = vtrack.naturalSize
    guard natural.width > 0, natural.height > 0 else {
      throw ConformError(stage: "open", message: "video track has no size")
    }
    // The clip's span is its VIDEO span: trailing audio past the last frame would otherwise
    // extend the output with black frames.
    let vEnd = vtrack.timeRange.end
    let span = CMTimeRange(start: .zero, end: vEnd.isValid && vEnd > .zero ? vEnd : asset.duration)
    guard span.duration > .zero else {
      throw ConformError(stage: "open", message: "clip has no duration")
    }

    let reader: AVAssetReader
    do { reader = try AVAssetReader(asset: asset) } catch {
      throw ConformError(stage: "reader", message: error.localizedDescription)
    }
    reader.timeRange = span

    try? FileManager.default.removeItem(at: output)
    let writer: AVAssetWriter
    do { writer = try AVAssetWriter(outputURL: output, fileType: .mp4) } catch {
      throw ConformError(stage: "writer", message: error.localizedDescription)
    }
    // moov ahead of mdat: progressive playback without a remux.
    writer.shouldOptimizeForNetworkUse = true

    var pairs: [(AVAssetReaderOutput, AVAssetWriterInput)] = []
    var cfr: (adaptor: AVAssetWriterInputPixelBufferAdaptor, fps: Int32)? = nil

    // --- Video ---
    if target.copyVideo {
      let out = AVAssetReaderTrackOutput(track: vtrack, outputSettings: nil)
      out.alwaysCopiesSampleData = false
      let hint = (vtrack.formatDescriptions as? [CMFormatDescription])?.first
      let input = AVAssetWriterInput(mediaType: .video, outputSettings: nil, sourceFormatHint: hint)
      input.transform = vtrack.preferredTransform
      input.expectsMediaDataInRealTime = false
      guard reader.canAdd(out), writer.canAdd(input) else {
        throw ConformError(stage: "video", message: "can't pass the video track through")
      }
      reader.add(out)
      writer.add(input)
      pairs.append((out, input))
    } else {
      let canvasW = CGFloat(target.canvasWidth & ~1)
      let canvasH = CGFloat(target.canvasHeight & ~1)
      let avfDeg = avfDegrees(fromProbeRotation: target.rotation)
      let swapped = avfDeg == 90 || avfDeg == 270
      let codedW = swapped ? canvasH : canvasW
      let codedH = swapped ? canvasW : canvasH
      let outTransform = trackTransform(avfDegrees: avfDeg)

      // Source coded frame → upright display frame at the origin (any rotation AND mirroring
      // in the source matrix is honored — the matrix is applied, not just its angle).
      let pt = vtrack.preferredTransform
      let rect = CGRect(origin: .zero, size: natural).applying(pt)
      let toUpright = normalized(pt, size: natural)
      let dispW = abs(rect.width), dispH = abs(rect.height)
      // Fit + center on the display canvas.
      let s = min(canvasW / dispW, canvasH / dispH)
      let fit = CGAffineTransform(scaleX: s, y: s)
        .concatenating(CGAffineTransform(translationX: (canvasW - dispW * s) / 2, y: (canvasH - dispH * s) / 2))
      // Display canvas → coded output orientation (inverse of the tag we write, normalized so
      // the coded frame lands at the origin of the render).
      let toCoded = normalized(outTransform.inverted(), size: CGSize(width: canvasW, height: canvasH))
      let layerTransform = toUpright.concatenating(fit).concatenating(toCoded)

      let comp = AVMutableVideoComposition()
      comp.renderSize = CGSize(width: codedW, height: codedH)
      comp.frameDuration = CMTime(value: 1, timescale: CMTimeScale(max(1, target.frameRate)))
      // Rendering into BT.709 is what tone-maps HDR sources (HLG/PQ/Dolby Vision) to SDR.
      comp.colorPrimaries = AVVideoColorPrimaries_ITU_R_709_2
      comp.colorTransferFunction = AVVideoTransferFunction_ITU_R_709_2
      comp.colorYCbCrMatrix = AVVideoYCbCrMatrix_ITU_R_709_2
      let instruction = AVMutableVideoCompositionInstruction()
      instruction.timeRange = span
      instruction.backgroundColor = CGColor(colorSpace: CGColorSpaceCreateDeviceRGB(), components: [0, 0, 0, 1])
      let layer = AVMutableVideoCompositionLayerInstruction(assetTrack: vtrack)
      layer.setTransform(layerTransform, at: .zero)
      instruction.layerInstructions = [layer]
      comp.instructions = [instruction]

      let out = AVAssetReaderVideoCompositionOutput(videoTracks: [vtrack], videoSettings: [
        kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
        kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any](),
      ])
      out.videoComposition = comp
      out.alwaysCopiesSampleData = false

      let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
        AVVideoCodecKey: AVVideoCodecType.h264,
        AVVideoWidthKey: Int(codedW),
        AVVideoHeightKey: Int(codedH),
        AVVideoColorPropertiesKey: [
          AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2,
          AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2,
          AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2,
        ],
        AVVideoCompressionPropertiesKey: [
          AVVideoAverageBitRateKey: target.bitrate,
          AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel,
          AVVideoExpectedSourceFrameRateKey: target.frameRate,
          AVVideoMaxKeyFrameIntervalKey: target.frameRate * 2,
        ],
      ])
      input.transform = outTransform
      input.expectsMediaDataInRealTime = false
      guard reader.canAdd(out), writer.canAdd(input) else {
        throw ConformError(stage: "video", message: "can't set up the video re-encode")
      }
      reader.add(out)
      writer.add(input)
      pairs.append((out, input))
      // The composition only emits a frame where the SOURCE has one (frameDuration caps the
      // rate, it doesn't pad it): a 24 fps or VFR source would come out 24/VFR and miss the
      // recorder's signature. Frames are re-timed onto exact 1/fps ticks instead.
      cfr = (AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: nil),
             Int32(max(1, target.frameRate)))
    }

    // --- Audio --- the track the platform itself would play: enabled first, AAC preferred,
    // never a Spatial Audio (APAC) companion when a regular track exists. A source whose audio
    // the platform can't decode at all fails here rather than coming out silent: the FFmpeg
    // fallback can usually decode it.
    let audioTracks = asset.tracks(withMediaType: .audio)
    let atrack = pickAudioTrack(asset)
    if atrack == nil && !audioTracks.isEmpty {
      throw ConformError(stage: "audio", message: "no natively decodable audio track")
    }
    if let atrack = atrack {
      var srcRate = 48000.0
      var srcCh = 2
      if let fd = (atrack.formatDescriptions as? [CMFormatDescription])?.first,
         let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(fd)?.pointee {
        if asbd.mSampleRate > 0 { srcRate = asbd.mSampleRate }
        if asbd.mChannelsPerFrame > 0 { srcCh = Int(asbd.mChannelsPerFrame) }
      }
      let rate = target.audioSampleRate > 0 ? Double(target.audioSampleRate) : aacRate(srcRate)
      let ch = target.audioChannels > 0 ? target.audioChannels : (srcCh == 6 ? 6 : min(srcCh, 2))
      guard let layout = channelLayoutData(ch) else {
        throw ConformError(stage: "audio", message: "unsupported channel count \(ch)")
      }
      let out = AVAssetReaderAudioMixOutput(audioTracks: [atrack], audioSettings: [
        AVFormatIDKey: kAudioFormatLinearPCM,
        AVSampleRateKey: rate,
        AVNumberOfChannelsKey: ch,
        AVChannelLayoutKey: layout,
        AVLinearPCMBitDepthKey: 32,
        AVLinearPCMIsFloatKey: true,
        AVLinearPCMIsBigEndianKey: false,
        AVLinearPCMIsNonInterleaved: false,
      ])
      out.alwaysCopiesSampleData = false
      var aac: [String: Any] = [
        AVFormatIDKey: kAudioFormatMPEG4AAC,
        AVSampleRateKey: rate,
        AVNumberOfChannelsKey: ch,
        AVChannelLayoutKey: layout,
      ]
      if rate >= 44100 { aac[AVEncoderBitRateKey] = ch == 1 ? 96_000 : ch == 2 ? 160_000 : 384_000 }
      let input = AVAssetWriterInput(mediaType: .audio, outputSettings: aac)
      input.expectsMediaDataInRealTime = false
      guard reader.canAdd(out), writer.canAdd(input) else {
        throw ConformError(stage: "audio", message: "can't set up the audio conform")
      }
      reader.add(out)
      writer.add(input)
      pairs.append((out, input))
    }

    return NativeConform(reader: reader, writer: writer, pairs: pairs, cfr: cfr, duration: span.duration, progress: progress)
  }

  // MARK: Pump

  private func start(output: URL, completion: @escaping (Result<URL, ConformError>) -> Void) {
    guard reader.startReading() else {
      completion(.failure(ConformError(stage: "reader", message: Self.describe(reader.error))))
      return
    }
    guard writer.startWriting() else {
      reader.cancelReading()
      completion(.failure(ConformError(stage: "writer", message: Self.describe(writer.error))))
      return
    }
    writer.startSession(atSourceTime: .zero)

    // Never hang. Once the job is cancelled or the pipeline has failed — e.g. iOS tore the
    // hardware encoder down when the app went to the background — the writer inputs may never ask
    // for data again, and the pumps below would wait forever. If they haven't wound down a second
    // after that, finish anyway.
    let watchdog = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
    var finished = false
    let finish: (Result<URL, ConformError>) -> Void = { [self] result in
      self.lock.lock()
      if finished {
        self.lock.unlock()
        return
      }
      finished = true
      self.lock.unlock()
      watchdog.cancel()
      completion(result)
    }
    var troubleSince: Date?
    watchdog.schedule(deadline: .now() + 0.25, repeating: 0.25)
    watchdog.setEventHandler { [self] in
      let trouble = self.isCancelled || self.reader.status == .failed || self.writer.status == .failed
      guard trouble else {
        troubleSince = nil
        return
      }
      guard let since = troubleSince else {
        troubleSince = Date()
        return
      }
      guard Date().timeIntervalSince(since) >= 1 else { return }
      self.reader.cancelReading()
      let error: ConformError
      if self.isCancelled {
        error = ConformError(stage: "encode", message: "cancelled")
      } else if self.writer.status == .failed {
        error = ConformError(stage: "encode", message: Self.describe(self.writer.error))
      } else {
        error = ConformError(stage: "decode", message: Self.describe(self.reader.error))
      }
      try? FileManager.default.removeItem(at: output)
      finish(.failure(error))
    }
    watchdog.resume()

    let group = DispatchGroup()
    let total = CMTimeGetSeconds(duration)
    var appended = [Int](repeating: 0, count: pairs.count)
    for (i, (out, input)) in pairs.enumerated() {
      group.enter()
      let queue = DispatchQueue(label: "native-conform.\(i)")
      if i == 0, let cfr = cfr {
        pumpConstantRate(out, input, cfr.adaptor, fps: cfr.fps, queue: queue) { n in
          self.lock.lock(); appended[0] = n; self.lock.unlock()
          group.leave()
        }
        continue
      }
      var finished = false
      let reportsProgress = i == 0
      input.requestMediaDataWhenReady(on: queue) { [self] in
        if finished { return }
        while input.isReadyForMoreMediaData {
          if self.isCancelled || self.reader.status != .reading {
            finished = true
            input.markAsFinished()
            group.leave()
            return
          }
          guard let sb = out.copyNextSampleBuffer() else {
            finished = true
            input.markAsFinished()
            group.leave()
            return
          }
          if !input.append(sb) {
            finished = true
            self.cancel()
            input.markAsFinished()
            group.leave()
            return
          }
          self.lock.lock(); appended[i] += 1; self.lock.unlock()
          if reportsProgress, let p = self.progress, total > 0 {
            let t = CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(sb))
            if t.isFinite { p(min(1, max(0, t / total))) }
          }
        }
      }
    }

    group.notify(queue: .global(qos: .userInitiated)) { [self] in
      if self.reader.status == .failed {
        self.writer.cancelWriting()
        finish(.failure(ConformError(stage: "decode", message: Self.describe(self.reader.error))))
        return
      }
      if self.writer.status == .failed {
        self.reader.cancelReading()
        finish(.failure(ConformError(stage: "encode", message: Self.describe(self.writer.error))))
        return
      }
      if self.isCancelled {
        self.writer.cancelWriting()
        finish(.failure(ConformError(stage: "encode", message: "cancelled")))
        return
      }
      // Some codecs (e.g. MP3 in an MP4) "open" natively but decode to nothing: an empty
      // track here means the audio would silently vanish — fail so FFmpeg handles the file.
      for (i, (_, input)) in self.pairs.enumerated() where appended[i] == 0 {
        self.writer.cancelWriting()
        finish(.failure(ConformError(stage: "decode", message: "\(input.mediaType.rawValue) track decoded to nothing")))
        return
      }
      self.writer.finishWriting {
        if self.writer.status == .completed {
          // A decoder that gives up silently (seen with AVI/MJPEG) ends the read early without
          // an error: never hand back an output that is materially shorter than the source.
          let got = CMTimeGetSeconds(AVURLAsset(url: output).duration)
          let want = CMTimeGetSeconds(self.duration)
          if want > 0.3 && got < want * 0.9 - 0.05 {
            try? FileManager.default.removeItem(at: output)
            finish(.failure(ConformError(stage: "verify", message: String(format: "output %.2fs of %.2fs source", got, want))))
            return
          }
          self.progress?(1)
          finish(.success(output))
        } else {
          finish(.failure(ConformError(stage: "finish", message: Self.describe(self.writer.error))))
        }
      }
    }
  }

  /// Append the video at exact 1/fps ticks: each tick shows the latest source frame at or
  /// before it (nearest, as FFmpeg's fps filter), duplicating across gaps (24 fps, VFR) and
  /// dropping surplus (60/120 fps). Calls `done` once with the number of frames written.
  private func pumpConstantRate(_ out: AVAssetReaderOutput, _ input: AVAssetWriterInput,
                                _ adaptor: AVAssetWriterInputPixelBufferAdaptor, fps: Int32,
                                queue: DispatchQueue, done: @escaping (Int) -> Void) {
    let half = 0.5 / Double(fps)
    let end = CMTimeGetSeconds(duration)
    let total = end
    func tick(_ k: Int64) -> CMTime { CMTime(value: k, timescale: fps) }
    var pending: [(CVPixelBuffer, CMTime)] = []
    var held: CVPixelBuffer?
    var heldPts = 0.0
    var lastInterval = 1.0 / Double(fps)
    var next: Int64 = 0
    var sourceDone = false
    var finished = false
    var written = 0
    func finish() {
      finished = true
      input.markAsFinished()
      done(written)
    }
    input.requestMediaDataWhenReady(on: queue) { [self] in
      if finished { return }
      while input.isReadyForMoreMediaData {
        if self.isCancelled || self.reader.status == .failed { finish(); return }
        if !pending.isEmpty {
          let (buffer, time) = pending.removeFirst()
          if !adaptor.append(buffer, withPresentationTime: time) {
            self.cancel()
            finish()
            return
          }
          written += 1
          if let p = self.progress, total > 0 { p(min(1, CMTimeGetSeconds(time) / total)) }
          continue
        }
        if sourceDone { finish(); return }
        if let sb = out.copyNextSampleBuffer() {
          guard let buffer = CMSampleBufferGetImageBuffer(sb) else { continue }
          let pts = CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(sb))
          if let h = held {
            while CMTimeGetSeconds(tick(next)) + half < pts {
              pending.append((h, tick(next)))
              next += 1
            }
            if pts > heldPts { lastInterval = pts - heldPts }
          }
          held = buffer
          heldPts = pts
        } else {
          sourceDone = true
          // The last frame covers only its own duration: padding it out to the declared end
          // would hide a decoder that stopped early behind a frozen frame (the duration check
          // must see a short output and fall back instead).
          if let h = held {
            let stop = min(end, heldPts + max(lastInterval, 1.0 / Double(fps)))
            while CMTimeGetSeconds(tick(next)) < stop - 1e-6 {
              pending.append((h, tick(next)))
              next += 1
            }
          }
        }
      }
    }
  }

  private var isCancelled: Bool {
    lock.lock(); defer { lock.unlock() }
    return cancelled
  }

  /// Stop the job: the reader is cancelled, nothing more is written, and the completion fails
  /// with "cancelled".
  public func cancel() {
    lock.lock(); cancelled = true; lock.unlock()
    reader.cancelReading()
  }

  // MARK: Helpers

  /// probeVideo reports FFprobe's display-matrix angle, which is the NEGATIVE of the
  /// preferredTransform's rotation angle (a camera portrait clip: transform +90°, probe 270).
  static func avfDegrees(fromProbeRotation r: Int) -> Int {
    let n = ((r % 360) + 360) % 360
    return (360 - n) % 360
  }

  /// Track transform for a pure quarter-turn, stored with zero translation — exactly the
  /// matrix camera recorders write (players normalize the displayed frame to the origin).
  static func trackTransform(avfDegrees d: Int) -> CGAffineTransform {
    switch d {
    case 90: return CGAffineTransform(a: 0, b: 1, c: -1, d: 0, tx: 0, ty: 0)
    case 180: return CGAffineTransform(a: -1, b: 0, c: 0, d: -1, tx: 0, ty: 0)
    case 270: return CGAffineTransform(a: 0, b: -1, c: 1, d: 0, tx: 0, ty: 0)
    default: return .identity
    }
  }

  /// `t` with the translation that puts the image of `size` back at the origin.
  static func normalized(_ t: CGAffineTransform, size: CGSize) -> CGAffineTransform {
    let r = CGRect(origin: .zero, size: size).applying(t)
    return t.concatenating(CGAffineTransform(translationX: -r.minX, y: -r.minY))
  }

  static func pickAudioTrack(_ asset: AVAsset) -> AVAssetTrack? {
    let tracks = asset.tracks(withMediaType: .audio)
    func subtype(_ t: AVAssetTrack) -> FourCharCode? {
      (t.formatDescriptions as? [CMFormatDescription])?.first.map { CMFormatDescriptionGetMediaSubType($0) }
    }
    let apac: FourCharCode = 0x6170_6163 // 'apac'
    let playable = tracks.filter { subtype($0) != apac && $0.isPlayable }
    return playable.first(where: { $0.isEnabled && subtype($0) == kAudioFormatMPEG4AAC })
      ?? playable.first(where: { $0.isEnabled })
      ?? playable.first
  }

  /// Nearest AAC-encodable rate at or below the source (AAC-LC tops out at 48 kHz).
  static func aacRate(_ r: Double) -> Double {
    let rates: [Double] = [48000, 44100, 32000, 24000, 22050, 16000, 12000, 11025, 8000]
    return rates.first(where: { $0 <= r + 1 }) ?? 8000
  }

  static func channelLayoutData(_ channels: Int) -> Data? {
    let tag: AudioChannelLayoutTag
    switch channels {
    case 1: tag = kAudioChannelLayoutTag_Mono
    case 2: tag = kAudioChannelLayoutTag_Stereo
    case 6: tag = kAudioChannelLayoutTag_MPEG_5_1_D
    default: return nil
    }
    var layout = AudioChannelLayout()
    layout.mChannelLayoutTag = tag
    return Data(bytes: &layout, count: MemoryLayout<AudioChannelLayout>.size)
  }

  static func describe(_ error: Error?) -> String {
    guard let e = error as NSError? else { return "unknown error" }
    var parts = ["\(e.domain) \(e.code): \(e.localizedDescription)"]
    if let u = e.userInfo[NSUnderlyingErrorKey] as? NSError {
      parts.append("underlying \(u.domain) \(u.code): \(u.localizedDescription)")
    }
    return parts.joined(separator: "; ")
  }
}
