import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'core/theme/app_theme.dart';
import 'features/subscriptions/presentation/screens/subscriptions_screen.dart';

void main() {
  runApp(const ProviderScope(child: EarshotApp()));
}

class EarshotApp extends StatelessWidget {
  const EarshotApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Earshot',
      theme: AppTheme.light(),
      darkTheme: AppTheme.dark(),
      highContrastTheme: AppTheme.highContrastLight(),
      highContrastDarkTheme: AppTheme.highContrastDark(),
      themeMode: ThemeMode.system,
      home: const SubscriptionsScreen(),
    );
  }
}
