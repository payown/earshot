import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'log_service.dart';

final logServiceProvider = Provider<LogService>(
  (ref) => throw StateError('logServiceProvider not initialized'),
);
