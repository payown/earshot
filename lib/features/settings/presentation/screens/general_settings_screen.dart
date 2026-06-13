import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/app_settings_repository.dart';
import '../providers/settings_providers.dart';

class GeneralSettingsScreen extends ConsumerWidget {
  const GeneralSettingsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final launchScreen =
        ref.watch(defaultLaunchScreenProvider).value ?? LaunchScreen.library;

    return Scaffold(
      appBar: AppBar(title: const Text('General')),
      body: ListView(
        children: [
          _LaunchScreenTile(
            currentScreen: launchScreen,
            onChanged: (screen) async {
              try {
                await ref
                    .read(defaultLaunchScreenProvider.notifier)
                    .set(screen);
                if (context.mounted) {
                  SemanticsService.sendAnnouncement(
                    View.of(context),
                    'Default launch screen set to ${_screenLabel(screen)}',
                    TextDirection.ltr,
                  );
                }
              } catch (_) {
                if (context.mounted) {
                  SemanticsService.sendAnnouncement(
                    View.of(context),
                    'Could not update default launch screen setting',
                    TextDirection.ltr,
                  );
                }
              }
            },
          ),
        ],
      ),
    );
  }
}

String _screenLabel(LaunchScreen screen) => switch (screen) {
  LaunchScreen.inbox => 'Inbox',
  LaunchScreen.queue => 'Queue',
  LaunchScreen.library => 'Library',
  LaunchScreen.downloads => 'Downloads',
};

class _LaunchScreenTile extends StatelessWidget {
  const _LaunchScreenTile({
    required this.currentScreen,
    required this.onChanged,
  });

  final LaunchScreen currentScreen;
  final Future<void> Function(LaunchScreen screen) onChanged;

  static const _title = 'Default launch screen';
  static const _barrierLabel = 'Dismiss default launch screen picker';

  Future<void> _showPicker(BuildContext context) async {
    final chosen = await showModalBottomSheet<LaunchScreen>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      barrierLabel: _barrierLabel,
      builder: (_) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 20, 16, 8),
              child: Semantics(
                header: true,
                label: _title,
                child: ExcludeSemantics(
                  child: Text(
                    _title,
                    style: Theme.of(context).textTheme.titleLarge,
                  ),
                ),
              ),
            ),
            RadioGroup<LaunchScreen>(
              groupValue: currentScreen,
              onChanged: (val) => Navigator.of(context).pop(val),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  for (final screen in LaunchScreen.values)
                    RadioListTile<LaunchScreen>(
                      title: Text(_screenLabel(screen)),
                      value: screen,
                    ),
                ],
              ),
            ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );

    if (chosen == null || chosen == currentScreen) return;
    await onChanged(chosen);
  }

  @override
  Widget build(BuildContext context) {
    return ListTile(
      title: const Text(_title),
      subtitle: Text(_screenLabel(currentScreen)),
      trailing: const ExcludeSemantics(child: Icon(Icons.chevron_right)),
      onTap: () => _showPicker(context),
    );
  }
}
