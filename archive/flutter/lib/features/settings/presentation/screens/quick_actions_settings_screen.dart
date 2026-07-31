import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../../../core/router/app_router.dart';
import '../../../../data/db/enums.dart';

class QuickActionsSettingsScreen extends StatelessWidget {
  const QuickActionsSettingsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Quick Actions')),
      body: ListView(
        children: [
          ListTile(
            title: const Text('Episode Quick Actions'),
            subtitle: const Text('Choose and reorder actions on episodes'),
            trailing: const ExcludeSemantics(child: Icon(Icons.chevron_right)),
            onTap: () => context.push(
              AppRoutes.settingsQuickActions(
                QuickActionContentType.episode.name,
              ),
            ),
          ),
          ListTile(
            title: const Text('Podcast Quick Actions'),
            subtitle: const Text('Choose and reorder actions on podcasts'),
            trailing: const ExcludeSemantics(child: Icon(Icons.chevron_right)),
            onTap: () => context.push(
              AppRoutes.settingsQuickActions(
                QuickActionContentType.podcast.name,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
