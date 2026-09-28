package com.videotrim.utils

import org.json.JSONObject
import java.io.File
import java.io.RandomAccessFile
import kotlin.math.abs
import kotlin.math.atan2
import kotlin.math.floor
import kotlin.math.hypot
import kotlin.math.roundToInt

/**
 * The FFmpeg conform command for `compress`, kept pure so it mirrors ios/ConformArgs.swift line
 * for line.
 *
 * Maps exactly the streams probeVideo describes (first real video — `V` skips cover art — and
 * the first audio; never FFmpeg's auto-pick, which prefers the most-channels audio, e.g. an
 * undecodable iPhone Spatial Audio APAC track), drops frames before scaling, squares anamorphic
 * pixels, deinterlaces flagged frames, tone-casts HLG/PQ when asked, orients mirrored sources
 * explicitly (FFmpeg 6.0's autorotate ignores flips) and writes coded-orientation pixels for
 * a rotation tag that [patchTrackRotation] stamps after the encode.
 */
object ConformArgs {
  data class Settings(
    val width: Int,
    val height: Int,
    val frameRate: Double,
    val letterbox: Boolean,
    val copyVideo: Boolean,
    val removeAudio: Boolean,
    val audioSampleRate: Int,
    val audioChannels: Int,
    val rotation: Int,
    val hdrToSdr: Boolean,
  )

  private const val HDR_TO_SDR = "colorspace=all=bt709:iall=bt2020:itrc=bt2020-10:format=yuv420p"

  fun formatRate(r: Double): String = if (r == Math.rint(r)) "${r.toLong()}" else "$r"

  /** `[-noautorotate] -i <url> -map 0:V:0 [-map 0:a:0?]` */
  fun inputArgs(url: String, s: Settings, matrix: DoubleArray?, audio: Boolean): List<String> = buildList {
    if (!s.copyVideo && isMirror(matrix)) add("-noautorotate")
    addAll(listOf("-i", url, "-map", "0:V:0"))
    if (audio) addAll(listOf("-map", "0:a:0?"))
  }

  /** The `-vf` chain for a re-encode (callers may append an encoder-specific cap). */
  fun videoFilters(s: Settings, matrix: DoubleArray?): MutableList<String> {
    val vf = if (isMirror(matrix)) orientationFilters(matrix!!).toMutableList() else mutableListOf()
    vf.add("yadif=mode=send_frame:deint=interlaced")
    // Drop frames FIRST: scaling/tone-mapping 120 fps of 4K to keep 30 is 4x wasted work.
    if (s.frameRate > 0) vf.add("fps=${formatRate(s.frameRate)}")
    // Square the pixels (anamorphic sources) before any fit.
    vf.addAll(listOf("scale=trunc(iw*sar/2)*2:ih", "setsar=1"))
    if (s.width > 0 && s.height > 0 && s.letterbox) {
      // Fit-and-pad onto an exact WxH DISPLAY canvas (post-autorotation), preserving aspect.
      val w = s.width and 1.inv()
      val h = s.height and 1.inv()
      vf.add("scale=$w:$h:force_original_aspect_ratio=decrease:force_divisible_by=2")
      if (s.hdrToSdr) vf.add(HDR_TO_SDR)
      vf.addAll(listOf("pad=$w:$h:(ow-iw)/2:(oh-ih)/2", "setsar=1"))
    } else {
      when {
        s.width > 0 && s.height > 0 -> vf.add("scale=${s.width}:${s.height}")
        s.width > 0 -> vf.add("scale=${s.width}:-2")
        s.height > 0 -> vf.add("scale=-2:${s.height}")
      }
      if (s.hdrToSdr) vf.add(HDR_TO_SDR)
    }
    // 8-bit 4:2:0 — hardware encoders reject 10-bit input.
    vf.add("format=yuv420p")
    // Pixels in the coded orientation that `rotation` will display upright.
    when (s.rotation) {
      90 -> vf.add("transpose=1")
      270 -> vf.add("transpose=2")
      180 -> vf.addAll(listOf("hflip", "vflip"))
    }
    return vf
  }

  fun audioArgs(s: Settings, audio: Boolean): List<String> = buildList {
    if (!audio) {
      add("-an")
      return@buildList
    }
    addAll(listOf("-c:a", "aac"))
    if (s.audioSampleRate > 0) addAll(listOf("-ar", "${s.audioSampleRate}"))
    if (s.audioChannels > 0) addAll(listOf("-ac", "${s.audioChannels}"))
  }

  /** The display matrix from a stream's FFprobe properties (FFmpeg order a b u c d v x y w). */
  fun displayMatrix(props: JSONObject?): DoubleArray? {
    val list = props?.optJSONArray("side_data_list") ?: return null
    for (i in 0 until list.length()) {
      val text = list.optJSONObject(i)?.optString("displaymatrix") ?: continue
      if (text.isEmpty()) continue
      val nums = text.split("\n").flatMap { line ->
        line.substringAfter(':', "").trim().split(Regex("\\s+")).mapNotNull { it.toDoubleOrNull() }
      }
      if (nums.size == 9) return nums.toDoubleArray()
    }
    return null
  }

  fun isMirror(m: DoubleArray?): Boolean = m != null && m[0] * m[4] - m[1] * m[3] < 0

  fun isAttachedPicture(props: JSONObject?): Boolean =
    props?.optJSONObject("disposition")?.optInt("attached_pic") == 1

  /** Port of FFmpeg ≥ 7's autorotate (fftools/ffmpeg_filter.c), which honors flips. */
  fun orientationFilters(m: DoubleArray): List<String> {
    fun fp(x: Double) = x / 65536
    val s0 = hypot(fp(m[0]), fp(m[3]))
    val s1 = hypot(fp(m[1]), fp(m[4]))
    if (s0 == 0.0 || s1 == 0.0) return emptyList()
    var theta = Math.round(atan2(fp(m[1]) / s1, fp(m[0]) / s0) * 180 / Math.PI).toDouble()
    theta -= 360 * floor(theta / 360 + 0.9 / 360)
    return when {
      abs(theta - 90) < 1 -> listOf("transpose=${if (m[3] > 0) "cclock_flip" else "clock"}")
      abs(theta - 180) < 1 -> (if (m[0] < 0) listOf("hflip") else emptyList()) + (if (m[4] < 0) listOf("vflip") else emptyList())
      abs(theta - 270) < 1 -> listOf("transpose=${if (m[3] < 0) "clock_flip" else "cclock"}")
      abs(theta) < 1 -> if (m[4] < 0) listOf("vflip") else emptyList()
      else -> listOf("rotate=${theta.roundToInt()}*PI/180")
    }
  }

  /**
   * Write a pure quarter-turn (probeVideo's convention) into the video track's tkhd matrix in
   * place. FFmpeg 6.0 can't write a display matrix; the output is faststart, so moov is up front
   * and the matrix is 36 bytes at a fixed tkhd offset.
   */
  fun patchTrackRotation(file: File, rotation: Int): Boolean {
    val r = ((rotation % 360) + 360) % 360
    val abcd = when (r) {
      90 -> intArrayOf(0, -1, 1, 0)
      180 -> intArrayOf(-1, 0, 0, -1)
      270 -> intArrayOf(0, 1, -1, 0)
      else -> intArrayOf(1, 0, 0, 1)
    }
    return try {
      RandomAccessFile(file, "rw").use { raf ->
        val size = raf.length()
        data class Box(val off: Long, val len: Long, val type: String, val head: Long)
        fun children(start: Long, end: Long): List<Box> {
          val out = mutableListOf<Box>()
          var off = start
          while (off + 8 <= end) {
            raf.seek(off)
            var len = raf.readInt().toLong() and 0xffffffffL
            val t = ByteArray(4).also { raf.readFully(it) }
            var head = 8L
            if (len == 1L) {
              len = raf.readLong()
              head = 16
            } else if (len == 0L) len = end - off
            if (len < 8) break
            out.add(Box(off, len, String(t, Charsets.ISO_8859_1), head))
            off += len
          }
          return out
        }
        val moov = children(0, size).firstOrNull { it.type == "moov" } ?: return false
        for (trak in children(moov.off + moov.head, moov.off + moov.len).filter { it.type == "trak" }) {
          val kids = children(trak.off + trak.head, trak.off + trak.len)
          val mdia = kids.firstOrNull { it.type == "mdia" } ?: continue
          val tkhd = kids.firstOrNull { it.type == "tkhd" } ?: continue
          val hdlr = children(mdia.off + mdia.head, mdia.off + mdia.len).firstOrNull { it.type == "hdlr" } ?: continue
          raf.seek(hdlr.off + hdlr.head + 8) // version/flags(4) pre_defined(4) handler_type
          val handler = ByteArray(4).also { raf.readFully(it) }
          if (String(handler, Charsets.ISO_8859_1) != "vide") continue
          raf.seek(tkhd.off + tkhd.head)
          val version = raf.readUnsignedByte()
          raf.seek(tkhd.off + tkhd.head + if (version == 1) 52 else 40)
          for (v in intArrayOf(abcd[0] shl 16, abcd[1] shl 16, 0, abcd[2] shl 16, abcd[3] shl 16, 0, 0, 0, 1 shl 30)) {
            raf.writeInt(v)
          }
          return true
        }
        false
      }
    } catch (_: Exception) {
      false
    }
  }
}
