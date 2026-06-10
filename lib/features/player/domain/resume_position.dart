/// Returns the position to resume playback from, or 0 to start over when the
/// episode is effectively finished (>= 95% of the known duration).
///
/// When the duration is unknown (many feeds omit itunes:duration) the saved
/// position is trusted as-is: restarting those episodes from 0 loses the
/// listener's place every time the app relaunches. The risk that motivated
/// clamping — loading at/past the media end makes the player report a
/// completed state immediately — is handled by the playback-evidence gates
/// in the audio handler and PositionTracker, which ignore completion events
/// that occur without any playback since load.
int clampedResumePosition({
  required int positionSeconds,
  required int? durationSeconds,
}) {
  if (positionSeconds <= 0) return 0;
  if (durationSeconds == null || durationSeconds <= 0) return positionSeconds;
  return positionSeconds < (durationSeconds * 0.95).round()
      ? positionSeconds
      : 0;
}
