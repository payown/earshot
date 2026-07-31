import 'package:earshot/core/utils/time_format.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('formatDurationSpoken', () {
    test('reads whole hours without minutes or seconds', () {
      expect(formatDurationSpoken(const Duration(hours: 42)), '42 hours');
    });

    test('includes seconds so 30-second steps are distinct', () {
      expect(
        formatDurationSpoken(const Duration(minutes: 4, seconds: 3)),
        '4 minutes 3 seconds',
      );
      expect(
        formatDurationSpoken(const Duration(minutes: 4, seconds: 33)),
        '4 minutes 33 seconds',
      );
    });

    test('uses singular units', () {
      expect(
        formatDurationSpoken(
          const Duration(hours: 1, minutes: 1, seconds: 1),
        ),
        '1 hour 1 minute 1 second',
      );
    });

    test('zero reads as "0 seconds"', () {
      expect(formatDurationSpoken(Duration.zero), '0 seconds');
    });

    test('drops zero middle/trailing units', () {
      expect(
        formatDurationSpoken(const Duration(hours: 2, seconds: 5)),
        '2 hours 5 seconds',
      );
      expect(formatDurationSpoken(const Duration(minutes: 4)), '4 minutes');
    });
  });

  group('formatDurationDigital', () {
    test('omits the hours field under an hour', () {
      expect(
        formatDurationDigital(const Duration(minutes: 4, seconds: 3)),
        '04:03',
      );
    });

    test('shows hours when present', () {
      expect(formatDurationDigital(const Duration(hours: 42)), '42:00:00');
    });
  });
}
