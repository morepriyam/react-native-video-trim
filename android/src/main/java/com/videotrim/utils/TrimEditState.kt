package com.videotrim.utils

import org.json.JSONArray
import org.json.JSONObject

/**
 * A saved editing session, round-tripped through JS as an opaque string
 * (`onFinishTrimming.editState` → `EditorConfig.editState`) so the editor can reopen where the
 * user left off, undo/redo history included. iOS writes and reads the same JSON
 * (`TrimEditState` in VideoTrimmerViewController.swift) — keep the two in sync. `crop` is
 * normalized (0–1) to the displayed video after rotation/flip; null = not cropped.
 */
data class TrimEditState(
  val v: Int,
  val startMs: Long,
  val endMs: Long,
  val rotation: Int,
  val flipped: Boolean,
  val crop: Crop?,
  val muted: Boolean,
  val speed: Double,
  val undo: List<Step> = emptyList(),
  val redo: List<Step> = emptyList()
) {
  data class Crop(val x: Double, val y: Double, val w: Double, val h: Double) {
    val isValid: Boolean
      get() = x >= 0 && y >= 0 && w > 0 && h > 0 && x + w <= 1 + EPSILON && y + h <= 1 + EPSILON

    fun toJson(): JSONObject = JSONObject().put("x", x).put("y", y).put("w", w).put("h", h)
  }

  /** One undo/redo step. `cropActive` with a null `crop` = crop tool open on the full frame. */
  data class Step(
    val startMs: Long,
    val endMs: Long,
    val rotation: Int,
    val flipped: Boolean,
    val cropActive: Boolean,
    val crop: Crop?,
    val muted: Boolean,
    val speed: Double
  ) {
    val isValid: Boolean
      get() = startMs >= 0 && endMs > startMs && rotation in 0..3 && speed in 0.25..4.0

    fun toJson(): JSONObject = JSONObject().apply {
      put("startMs", startMs)
      put("endMs", endMs)
      put("rotation", rotation)
      put("flipped", flipped)
      put("cropActive", cropActive)
      put("crop", crop?.toJson() ?: JSONObject.NULL)
      put("muted", muted)
      put("speed", speed)
    }
  }

  fun toJson(): String = JSONObject().apply {
    put("v", v)
    put("startMs", startMs)
    put("endMs", endMs)
    put("rotation", rotation)
    put("flipped", flipped)
    put("crop", crop?.toJson() ?: JSONObject.NULL)
    put("muted", muted)
    put("speed", speed)
    put("undo", JSONArray(undo.map { it.toJson() }))
    put("redo", JSONArray(redo.map { it.toJson() }))
  }.toString()

  companion object {
    const val CURRENT_VERSION = 1
    /** Undo/redo history is capped when saved; older steps are dropped. */
    const val MAX_HISTORY = 50
    private const val EPSILON = 0.001

    /**
     * Null for malformed, out-of-range or newer-version input, so a bad value degrades to
     * "open fresh" rather than a broken editor. An invalid crop alone is dropped, and history
     * is best-effort: steps that don't make sense are skipped.
     */
    fun fromJson(json: String): TrimEditState? = try {
      val o = JSONObject(json)
      val state = TrimEditState(
        v = o.getInt("v"),
        startMs = o.getDouble("startMs").toLong(),
        endMs = o.getDouble("endMs").toLong(),
        rotation = o.getInt("rotation"),
        flipped = o.getBoolean("flipped"),
        crop = parseCrop(o),
        muted = o.getBoolean("muted"),
        speed = o.getDouble("speed"),
        undo = parseSteps(o.optJSONArray("undo")),
        redo = parseSteps(o.optJSONArray("redo"))
      )
      state.takeIf {
        it.v in 1..CURRENT_VERSION && it.startMs >= 0 && it.endMs > it.startMs &&
          it.rotation in 0..3 && it.speed in 0.25..4.0
      }
    } catch (e: Exception) {
      null
    }

    private fun parseCrop(o: JSONObject): Crop? {
      if (!o.has("crop") || o.isNull("crop")) return null
      val c = o.getJSONObject("crop")
      return Crop(c.getDouble("x"), c.getDouble("y"), c.getDouble("w"), c.getDouble("h")).takeIf { it.isValid }
    }

    private fun parseSteps(array: JSONArray?): List<Step> {
      if (array == null) return emptyList()
      return (0 until array.length()).mapNotNull { i ->
        try {
          val o = array.getJSONObject(i)
          Step(
            startMs = o.getDouble("startMs").toLong(),
            endMs = o.getDouble("endMs").toLong(),
            rotation = o.getInt("rotation"),
            flipped = o.getBoolean("flipped"),
            cropActive = o.getBoolean("cropActive"),
            crop = parseCrop(o),
            muted = o.getBoolean("muted"),
            speed = o.getDouble("speed")
          ).takeIf { it.isValid }
        } catch (e: Exception) {
          null
        }
      }.takeLast(MAX_HISTORY)
    }
  }
}
