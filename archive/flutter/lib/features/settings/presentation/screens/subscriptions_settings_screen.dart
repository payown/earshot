import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

import '../../../../core/router/app_router.dart';
import '../../../../features/folders/presentation/providers/folders_providers.dart';
import '../../../../features/search/presentation/providers/search_providers.dart';
import '../../../../features/subscriptions/presentation/providers/subscriptions_providers.dart';

class SubscriptionsSettingsScreen extends ConsumerWidget {
  const SubscriptionsSettingsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Scaffold(
      appBar: AppBar(title: const Text('Subscriptions')),
      body: ListView(
        children: [
          ListTile(
            title: const Text('Import OPML'),
            subtitle: const Text('Import subscriptions from another app'),
            trailing: const ExcludeSemantics(child: Icon(Icons.chevron_right)),
            onTap: () => context.push(AppRoutes.settingsImportOpml),
          ),
          ListTile(
            title: const Text('Export OPML'),
            subtitle: const Text('Share your subscriptions list'),
            trailing: const ExcludeSemantics(child: Icon(Icons.share)),
            onTap: () => _exportOpml(context, ref),
          ),
          ListTile(
            title: const Text('Export OPML with folders'),
            subtitle: const Text('Share subscriptions grouped by folder'),
            trailing: const ExcludeSemantics(child: Icon(Icons.share)),
            onTap: () => _exportOpmlWithFolders(context, ref),
          ),
        ],
      ),
    );
  }

  Future<void> _exportOpmlWithFolders(
    BuildContext context,
    WidgetRef ref,
  ) async {
    final groups = await ref
        .read(folderRepositoryProvider)
        .getAllWithFolderStructure();

    final hasContent = groups.any((g) => g.podcasts.isNotEmpty);
    if (!hasContent) {
      if (context.mounted) {
        const msg = 'No subscriptions to export.';
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text(msg)),
        );
        SemanticsService.sendAnnouncement(
          View.of(context),
          msg,
          TextDirection.ltr,
        );
      }
      return;
    }

    final xml = ref.read(opmlServiceProvider).generateWithFolders(groups);
    final dir = await getTemporaryDirectory();
    final file = File('${dir.path}/earshot-subscriptions-folders.opml');
    await file.writeAsString(xml);

    if (context.mounted) {
      await SharePlus.instance.share(
        ShareParams(
          files: [XFile(file.path, mimeType: 'text/x-opml')],
          subject: 'Earshot Subscriptions',
        ),
      );
    }
  }

  Future<void> _exportOpml(BuildContext context, WidgetRef ref) async {
    final podcasts = ref.read(subscriptionsProvider).asData?.value ?? [];
    if (podcasts.isEmpty) {
      if (context.mounted) {
        const msg = 'No subscriptions to export.';
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text(msg)),
        );
        SemanticsService.sendAnnouncement(
          View.of(context),
          msg,
          TextDirection.ltr,
        );
      }
      return;
    }

    final subs = podcasts
        .map((p) => (rssUrl: p.rssUrl, title: p.title))
        .toList();
    final xml = ref.read(opmlServiceProvider).generate(subs);

    final dir = await getTemporaryDirectory();
    final file = File('${dir.path}/earshot-subscriptions.opml');
    await file.writeAsString(xml);

    if (context.mounted) {
      await SharePlus.instance.share(
        ShareParams(
          files: [XFile(file.path, mimeType: 'text/x-opml')],
          subject: 'Earshot Subscriptions',
        ),
      );
    }
  }
}
