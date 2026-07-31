String formatBytes(int bytes) {
  if (bytes < 1024) return '$bytes B';
  final kb = bytes / 1024;
  if (kb < 1024) return '${_trim(kb)} KB';
  final mb = kb / 1024;
  if (mb < 1024) return '${_trim(mb)} MB';
  return '${_trim(mb / 1024)} GB';
}

String _trim(double n) {
  if (n == n.truncateToDouble()) return n.toInt().toString();
  return n.toStringAsFixed(1);
}
