import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../features/player/presentation/providers/player_providers.dart';

class AccessibilitySettingsScreen extends ConsumerWidget {
  const AccessibilitySettingsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Scaffold(
      appBar: AppBar(title: const Text('Accessibility')),
      body: ListView(
        children: [
          SwitchListTile(
            title: const Text('Direct Touch Mode'),
            subtitle: const Text(
              'Enables gesture controls on the artwork area for VoiceOver and TalkBack users',
            ),
            value: ref.watch(directTouchEnabledProvider).value ?? false,
            onChanged: ref.watch(directTouchEnabledProvider).isLoading
                ? null
                : (val) {
                    ref.read(directTouchEnabledProvider.notifier).set(val);
                    SemanticsService.sendAnnouncement(
                      View.of(context),
                      val
                          ? 'Direct Touch Mode enabled'
                          : 'Direct Touch Mode disabled',
                      TextDirection.ltr,
                    );
                  },
          ),
        ],
      ),
    );
  }
}
