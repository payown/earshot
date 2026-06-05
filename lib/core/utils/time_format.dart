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
