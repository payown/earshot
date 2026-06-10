/// Returns the position to resume playback from, or 0 to start over when the
/// episode is effectively finished (>= 95% of the known duration) or the
/// duration is unknown.
///
/// Restoring at or past the media end makes the player report a completed
/// state immediately on load, which would falsely mark the episode played.
int clampedResumePosition({
  required int positionSeconds,
  required int? durationSeconds,
}) {
  if (positionSeconds <= 0) return 0;
  if (durationSeconds == null || durationSeconds <= 0) return 0;
  return positionSeconds < (durationSeconds * 0.95).round()
      ? positionSeconds
      : 0;
}
