import 'package:flutter/foundation.dart';

@immutable
class Chapter {
  const Chapter({
    required this.index,
    required this.startTime,
    required this.title,
    this.imageUrl,
  });

  final int index;
  final double startTime; // seconds
  final String title;
  final String? imageUrl;
}
