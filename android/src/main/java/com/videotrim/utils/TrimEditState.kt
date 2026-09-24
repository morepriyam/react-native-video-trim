package com.videotrim.utils

import org.json.JSONObject

/**
 * A saved editing session, round-tripped through JS as an opaque string
 * (`onFinishTrimming.editState` → `EditorConfig.editState`) so the editor can reopen where the
 * user left off. iOS writes and reads the same JSON (`TrimEditState` in
 * VideoTrimmerViewController.swift) — keep the two in sync. `crop` is normalized (0–1) to the
 * displayed video after rotation/flip; null = not cropped.
 */
data class TrimEditState(
  val v: Int,
  val startMs: Long,
  val endMs: Long,
  val rotation: Int,
  val flipped: Boolean,
  val crop: Crop?,
  val muted: Boolean,
  val speed: Double
) {
  data class Crop(val x: Double, val y: Double, val w: Double, val h: Double) {
    val isValid: Boolean
      get() = x >= 0 && y >= 0 && w > 0 && h > 0 && x + w <= 1 + EPSILON && y + h <= 1 + EPSILON
  }

  fun toJson(): String = JSONObject().apply {
    put("v", v)
    put("startMs", startMs)
    put("endMs", endMs)
    put("rotation", rotation)
    put("flipped", flipped)
    put("crop", crop?.let { JSONObject().put("x", it.x).put("y", it.y).put("w", it.w).put("h", it.h) } ?: JSONObject.NULL)
    put("muted", muted)
    put("speed", speed)
  }.toString()

  companion object {
    const val CURRENT_VERSION = 1
    private const val EPSILON = 0.001

    /**
     * Null for malformed, out-of-range or newer-version input, so a bad value degrades to
     * "open fresh" rather than a broken editor. An invalid crop alone is dropped.
     */
    fun fromJson(json: String): TrimEditState? = try {
      val o = JSONObject(json)
      val crop = if (o.has("crop") && !o.isNull("crop")) {
        o.getJSONObject("crop").let { Crop(it.getDouble("x"), it.getDouble("y"), it.getDouble("w"), it.getDouble("h")) }
      } else {
        null
      }
      val state = TrimEditState(
        v = o.getInt("v"),
        startMs = o.getDouble("startMs").toLong(),
        endMs = o.getDouble("endMs").toLong(),
        rotation = o.getInt("rotation"),
        flipped = o.getBoolean("flipped"),
        crop = crop?.takeIf { it.isValid },
        muted = o.getBoolean("muted"),
        speed = o.getDouble("speed")
      )
      state.takeIf {
        it.v in 1..CURRENT_VERSION && it.startMs >= 0 && it.endMs > it.startMs &&
          it.rotation in 0..3 && it.speed in 0.25..4.0
      }
    } catch (e: Exception) {
      null
    }
  }
}
