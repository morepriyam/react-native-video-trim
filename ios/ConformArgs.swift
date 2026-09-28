import Foundation

// MARK: - FFmpeg conform command (pure — no FFmpegKit/UIKit)
//
// The FFmpeg half of `compress`: the settings it takes, the exact argv, and the post-encode
// rotation stamp. Kept dependency-free (no FFmpegKit/UIKit) so it can be compiled and tested
// on its own; android/.../utils/ConformArgs.kt mirrors it line for line.
public enum ConformArgs {
  public struct Settings {
    let quality: String, bitrate: Double, width: Int, height: Int, frameRate: Double
    let outputExt: String, removeAudio: Bool, codec: String
    let audioSampleRate: Int, audioChannels: Int, copyVideo: Bool, letterbox: Bool
    let engine: String, rotation: Int, hdrToSdr: Bool

    public init(_ o: NSDictionary) {
      quality = o["quality"] as? String ?? "medium"
      bitrate = o["bitrate"] as? Double ?? -1
      width = o["width"] as? Int ?? -1
      height = o["height"] as? Int ?? -1
      frameRate = o["frameRate"] as? Double ?? -1
      outputExt = o["outputExt"] as? String ?? "mp4"
      removeAudio = o["removeAudio"] as? Bool ?? false
      codec = o["codec"] as? String ?? "h264"
      audioSampleRate = o["audioSampleRate"] as? Int ?? -1
      audioChannels = o["audioChannels"] as? Int ?? -1
      copyVideo = o["copyVideo"] as? Bool ?? false
      letterbox = o["letterbox"] as? Bool ?? false
      engine = o["engine"] as? String ?? "ffmpeg"
      rotation = ((((o["rotation"] as? Int) ?? 0) % 360) + 360) % 360
      hdrToSdr = o["hdrToSdr"] as? Bool ?? false
    }
  }

  public static func ffmpegArgs(input: String, s: Settings, output: URL, matrix: [Double]?, audio: Bool) -> [String] {
    var cmds: [String] = []
    let mirrored = !s.copyVideo && isMirror(matrix)
    if !s.copyVideo { cmds.append(contentsOf: ["-hwaccel", "videotoolbox"]) }
    if mirrored { cmds.append("-noautorotate") }
    cmds.append(contentsOf: ["-i", input, "-map", "0:V:0"])
    if audio { cmds.append(contentsOf: ["-map", "0:a:0?"]) }

    if s.copyVideo {
      // Audio-only conform: the video track is stream-copied untouched. All
      // video options (scale/quality/bitrate/frameRate/codec) are skipped.
      cmds.append(contentsOf: ["-c:v", "copy"])
    } else {
      var vf: [String] = mirrored ? orientationFilters(matrix!) : []
      vf.append("yadif=mode=send_frame:deint=interlaced")
      // Drop frames FIRST: scaling/tone-mapping 120 fps of 4K to keep 30 is 4x wasted work.
      if s.frameRate > 0 { vf.append("fps=\(formatRate(s.frameRate))") }
      // Square the pixels (anamorphic sources) before any fit.
      vf.append(contentsOf: ["scale=trunc(iw*sar/2)*2:ih", "setsar=1"])
      let hdr = "colorspace=all=bt709:iall=bt2020:itrc=bt2020-10:format=yuv420p"
      if s.width > 0 && s.height > 0 && s.letterbox {
        // Fit-and-pad onto an exact WxH DISPLAY canvas (post-autorotation), preserving aspect.
        let w = s.width & ~1
        let h = s.height & ~1
        vf.append("scale=\(w):\(h):force_original_aspect_ratio=decrease:force_divisible_by=2")
        if s.hdrToSdr { vf.append(hdr) }
        vf.append(contentsOf: ["pad=\(w):\(h):(ow-iw)/2:(oh-ih)/2", "setsar=1"])
      } else {
        if s.width > 0 && s.height > 0 { vf.append("scale=\(s.width):\(s.height)") }
        else if s.width > 0 { vf.append("scale=\(s.width):-2") }
        else if s.height > 0 { vf.append("scale=-2:\(s.height)") }
        if s.hdrToSdr { vf.append(hdr) }
      }
      // 8-bit 4:2:0 for the hardware encoders (10-bit input fails to open them).
      vf.append("format=yuv420p")
      // Pixels in the coded orientation that `rotation` will display upright.
      switch s.rotation {
      case 90: vf.append("transpose=1")
      case 270: vf.append("transpose=2")
      case 180: vf.append(contentsOf: ["hflip", "vflip"])
      default: break
      }
      cmds.append(contentsOf: ["-vf", vf.joined(separator: ",")])

      if s.codec == "hevc" {
        // hvc1 tag so the MP4 plays on Apple players (which reject hev1).
        cmds.append(contentsOf: ["-c:v", "hevc_videotoolbox", "-tag:v", "hvc1"])
      } else {
        cmds.append(contentsOf: ["-c:v", "h264_videotoolbox", "-profile:v", "high"])
      }
      if s.bitrate > 0 {
        cmds.append(contentsOf: ["-b:v", "\(Int(s.bitrate))"])
      } else {
        let crf: String
        switch s.quality {
        case "low": crf = "28"
        case "high": crf = "18"
        default: crf = "23"
        }
        cmds.append(contentsOf: ["-global_quality", crf])
      }
      if s.frameRate > 0 { cmds.append(contentsOf: ["-r", formatRate(s.frameRate)]) }
    }

    if audio {
      cmds.append(contentsOf: ["-c:a", "aac"])
      if s.audioSampleRate > 0 { cmds.append(contentsOf: ["-ar", "\(s.audioSampleRate)"]) }
      if s.audioChannels > 0 { cmds.append(contentsOf: ["-ac", "\(s.audioChannels)"]) }
    } else {
      cmds.append("-an")
    }
    cmds.append(contentsOf: ["-sn", "-dn"])
    if ["mp4", "mov", "m4v"].contains(output.pathExtension.lowercased()) {
      cmds.append(contentsOf: ["-movflags", "+faststart"])
    }
    cmds.append(contentsOf: ["-y", output.path])
    return cmds
  }

  static func formatRate(_ r: Double) -> String {
    r == r.rounded() ? "\(Int(r))" : "\(r)"
  }

  static func displayMatrix(fromProperties props: [AnyHashable: Any]) -> [Double]? {
    guard let list = props["side_data_list"] as? [[AnyHashable: Any]] else { return nil }
    for sd in list {
      guard let text = sd["displaymatrix"] as? String else { continue }
      // "\n00000000:            0       65536           0\n00000001: ..." → 9 numbers.
      let nums = text.split(separator: "\n").flatMap { line -> [Double] in
        let body = line.split(separator: ":", maxSplits: 1).last.map(String.init) ?? ""
        return body.split(separator: " ").compactMap { Double($0) }
      }
      if nums.count == 9 { return nums }
    }
    return nil
  }

  static func isMirror(_ m: [Double]?) -> Bool {
    guard let m = m else { return false }
    return m[0] * m[4] - m[1] * m[3] < 0
  }

  /// Filters that orient a coded frame for display INCLUDING mirroring — a port of FFmpeg ≥ 7's
  /// autorotate (fftools/ffmpeg_filter.c); FFmpeg 6.0's applies only the angle.
  static func orientationFilters(_ m: [Double]) -> [String] {
    let fp = { (x: Double) in x / 65536 }
    let s0 = hypot(fp(m[0]), fp(m[3]))
    let s1 = hypot(fp(m[1]), fp(m[4]))
    guard s0 > 0, s1 > 0 else { return [] }
    var theta = (atan2(fp(m[1]) / s1, fp(m[0]) / s0) * 180 / .pi).rounded()
    theta -= 360 * floor(theta / 360 + 0.9 / 360)
    if abs(theta - 90) < 1 { return ["transpose=\(m[3] > 0 ? "cclock_flip" : "clock")"] }
    if abs(theta - 180) < 1 { return (m[0] < 0 ? ["hflip"] : []) + (m[4] < 0 ? ["vflip"] : []) }
    if abs(theta - 270) < 1 { return ["transpose=\(m[3] < 0 ? "clock_flip" : "cclock")"] }
    if abs(theta) < 1 { return m[4] < 0 ? ["vflip"] : [] }
    return ["rotate=\(Int(theta))*PI/180"]
  }

  /// Write a pure quarter-turn (probeVideo's convention) into the video track's tkhd matrix in
  /// place. FFmpeg 6.0 can't write a display matrix (`-display_rotation` is 6.1+ and the legacy
  /// `rotate` tag is ignored); the output is faststart, so moov is up front and the matrix is 36
  /// bytes at a fixed tkhd offset.
  static func patchTrackRotation(_ url: URL, rotation: Int) -> Bool {
    let r = ((rotation % 360) + 360) % 360
    let abcd: [Int32] = r == 90 ? [0, -1, 1, 0] : r == 180 ? [-1, 0, 0, -1] : r == 270 ? [0, 1, -1, 0] : [1, 0, 0, 1]
    guard let fh = try? FileHandle(forUpdating: url) else { return false }
    defer { try? fh.close() }
    let size = (try? fh.seekToEnd()) ?? 0

    func read(_ off: UInt64, _ n: Int) -> Data {
      try? fh.seek(toOffset: off)
      return (try? fh.read(upToCount: n)) ?? Data()
    }
    func u32(_ d: Data, _ i: Int) -> UInt64 { d.count >= i + 4 ? d[d.startIndex + i ..< d.startIndex + i + 4].reduce(0) { $0 << 8 | UInt64($1) } : 0 }
    struct Box { let off: UInt64; let len: UInt64; let type: String; let head: UInt64 }
    func children(_ start: UInt64, _ end: UInt64) -> [Box] {
      var out: [Box] = []
      var off = start
      while off + 8 <= end {
        let h = read(off, 16)
        guard h.count >= 8 else { break }
        var len = u32(h, 0)
        let type = String(bytes: h[h.startIndex + 4 ..< h.startIndex + 8], encoding: .isoLatin1) ?? ""
        var head: UInt64 = 8
        if len == 1 { len = (u32(h, 8) << 32) | u32(h, 12); head = 16 } else if len == 0 { len = end - off }
        guard len >= 8 else { break }
        out.append(Box(off: off, len: len, type: type, head: head))
        off += len
      }
      return out
    }
    guard let moov = children(0, size).first(where: { $0.type == "moov" }) else { return false }
    for trak in children(moov.off + moov.head, moov.off + moov.len) where trak.type == "trak" {
      let kids = children(trak.off + trak.head, trak.off + trak.len)
      guard let mdia = kids.first(where: { $0.type == "mdia" }),
            let tkhd = kids.first(where: { $0.type == "tkhd" }),
            let hdlr = children(mdia.off + mdia.head, mdia.off + mdia.len).first(where: { $0.type == "hdlr" }),
            String(data: read(hdlr.off + hdlr.head + 8, 4), encoding: .isoLatin1) == "vide" else { continue }
      let version = read(tkhd.off + tkhd.head, 1).first ?? 0
      var matrix = Data()
      for v in [abcd[0] << 16, abcd[1] << 16, 0, abcd[2] << 16, abcd[3] << 16, 0, 0, 0, Int32(1 << 30)] {
        withUnsafeBytes(of: v.bigEndian) { matrix.append(contentsOf: $0) }
      }
      do {
        try fh.seek(toOffset: tkhd.off + tkhd.head + (version == 1 ? 52 : 40))
        try fh.write(contentsOf: matrix)
        return true
      } catch {
        return false
      }
    }
    return false
  }
}
