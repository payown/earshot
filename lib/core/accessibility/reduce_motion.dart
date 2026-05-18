import 'package:flutter/material.dart';

extension ReduceMotion on BuildContext {
  bool get disableAnimations => MediaQuery.of(this).disableAnimations;

  // Returns zero duration when Reduce Motion is on, otherwise the given duration.
  Duration motionDuration(Duration duration) =>
      disableAnimations ? Duration.zero : duration;
}
