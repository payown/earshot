import 'dart:async';
import 'dart:io';

import 'package:logging/logging.dart';
import 'package:path_provider/path_provider.dart';

class LogService {
  LogService._(this._file);

  final File _file;
  StreamSubscription<LogRecord>? _sub;
  int _recordCount = 0;

  static Future<LogService> init() async {
    final dir = await getApplicationSupportDirectory();
    final file = File('${dir.path}/earshot_debug.log');
    final service = LogService._(file);
    service._start();
    return service;
  }

  void _start() {
    _sub = Logger.root.onRecord.listen(_append);
  }

  void _append(LogRecord r) {
    final buf = StringBuffer()
      ..write('[')
      ..write(r.time.toIso8601String())
      ..write('][')
      ..write(r.level.name)
      ..write('][')
      ..write(r.loggerName)
      ..write('] ')
      ..write(r.message);
    if (r.error != null) buf.write(' | ${r.error}');
    buf.writeln();

    try {
      _file.writeAsStringSync(buf.toString(), mode: FileMode.append);
      _recordCount++;
      if (_recordCount % 200 == 0) _trim();
    } catch (_) {
      // Never throw from a log handler.
    }
  }

  void _trim() {
    try {
      if (!_file.existsSync() || _file.lengthSync() < 400 * 1024) return;
      final lines = _file.readAsLinesSync();
      _file.writeAsStringSync(
        '${lines.sublist(lines.length ~/ 2).join('\n')}\n',
      );
    } catch (_) {}
  }

  Future<File> ensureLogFile() async {
    if (!_file.existsSync()) {
      _file.writeAsStringSync(
        '[${DateTime.now().toIso8601String()}][INFO][LogService] Log initialized\n',
      );
    }
    return _file;
  }

  String get logFilePath => _file.path;

  void dispose() => _sub?.cancel();
}
