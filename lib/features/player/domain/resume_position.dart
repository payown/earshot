import '../../../data/db/enums.dart';

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

/// Whether the last-playing episode should be restored to the mini player on
/// cold start.
///
/// A non-played episode is always restored. A `played` episode is normally
/// skipped (it genuinely finished and PositionTracker zeroed its position),
/// but is still restored when it retains a non-zero position: that only
/// happens when a spurious/racing completion marked it played mid-episode, in
/// which case the listener should get their place back rather than an empty
/// mini player. See issue #293.
bool shouldRestoreLastPlaying({
  required EpisodeStatus status,
  required int positionSeconds,
}) => status != EpisodeStatus.played || positionSeconds > 0;
