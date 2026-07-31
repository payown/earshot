/// A compact digital duration for visual display: `M:SS` under an hour,
/// `H:MM:SS` at or above one hour (e.g. `04:03`, `42:00:00`).
String formatDurationDigital(Duration d) {
  final h = d.inHours;
  final m = d.inMinutes.remainder(60).toString().padLeft(2, '0');
  final s = d.inSeconds.remainder(60).toString().padLeft(2, '0');
  return h > 0 ? '$h:$m:$s' : '$m:$s';
}

/// A natural-language duration for screen readers (e.g. "4 minutes 3 seconds",
/// "42 hours"). Includes seconds whenever they are non-zero so a 30-second
/// seek step always changes the announced value, and is the single spoken time
/// format used across the player's seek slider (#328).
String formatDurationSpoken(Duration d) {
  final h = d.inHours;
  final m = d.inMinutes.remainder(60);
  final s = d.inSeconds.remainder(60);
  final parts = <String>[
    if (h > 0) '$h ${h == 1 ? 'hour' : 'hours'}',
    if (m > 0) '$m ${m == 1 ? 'minute' : 'minutes'}',
    if (s > 0) '$s ${s == 1 ? 'second' : 'seconds'}',
  ];
  if (parts.isEmpty) return '0 seconds';
  return parts.join(' ');
}

String formatTimeOfDay(DateTime dt) {
  final hour = dt.hour % 12 == 0 ? 12 : dt.hour % 12;
  final minute = dt.minute.toString().padLeft(2, '0');
  final period = dt.hour < 12 ? 'AM' : 'PM';
  return '$hour:$minute $period';
}

/// Returns a human-readable feed-check timestamp for display in debug UI.
/// null  → "never"
/// today → "today at 3:42 PM"
/// other → "Jan 1 at 3:42 PM"
String formatRefreshTimestamp(DateTime? dt) {
  if (dt == null) return 'never';
  final local = dt.toLocal();
  final now = DateTime.now();
  const months = [
    'Jan',
    'Feb',
    'Mar',
    'Apr',
    'May',
    'Jun',
    'Jul',
    'Aug',
    'Sep',
    'Oct',
    'Nov',
    'Dec',
  ];
  final time = formatTimeOfDay(local);
  final sameDay =
      local.year == now.year &&
      local.month == now.month &&
      local.day == now.day;
  if (sameDay) return 'today at $time';
  return '${months[local.month - 1]} ${local.day} at $time';
}
