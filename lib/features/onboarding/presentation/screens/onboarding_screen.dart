import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/providers/core_providers.dart';
import '../../../../features/search/presentation/screens/search_screen.dart';
import '../../../../features/settings/data/app_settings_repository.dart';
import '../../../../features/subscriptions/presentation/screens/add_podcast_screen.dart';

class OnboardingScreen extends ConsumerStatefulWidget {
  const OnboardingScreen({super.key});

  @override
  ConsumerState<OnboardingScreen> createState() => _OnboardingScreenState();
}

class _OnboardingScreenState extends ConsumerState<OnboardingScreen> {
  final _pageController = PageController();
  int _currentPage = 0;
  bool _hasAddedPodcast = false;

  static const _totalPages = 7;

  @override
  void dispose() {
    _pageController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Semantics(
                    label: 'Page ${_currentPage + 1} of $_totalPages',
                    child: ExcludeSemantics(
                      child: Text(
                        '${_currentPage + 1} / $_totalPages',
                        style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: Theme.of(context).colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ),
                  ),
                  TextButton(
                    onPressed: _finish,
                    child: const Text('Skip'),
                  ),
                ],
              ),
            ),
            Expanded(
              child: PageView(
                controller: _pageController,
                onPageChanged: (i) => setState(() => _currentPage = i),
                children: [
                  const _OnboardingPage(
                    icon: Icons.headphones,
                    title: 'Welcome to Earshot',
                    body: 'A podcast player built for the way you listen.',
                  ),
                  const _OnboardingPage(
                    icon: Icons.move_down,
                    title: 'How your content flows',
                    body:
                        'Subscribe to a podcast, and new episodes arrive in your Inbox. '
                        'Triage them into your Queue when you\'re ready to listen. '
                        'Mark a podcast as Auto-Queue and new episodes skip Inbox entirely.',
                  ),
                  _PrivacyPage(),
                  const _OnboardingPage(
                    icon: Icons.swipe_up_alt,
                    title: 'Quick Actions',
                    body:
                        'Every episode and podcast has Quick Actions — shortcuts you can '
                        'reorder to match how you listen. On a screen reader, swipe up '
                        'or down to access them. You can customize the order in Settings.',
                  ),
                  const _OnboardingPage(
                    icon: Icons.timer_off,
                    title: 'Queue expiration',
                    body:
                        'Tired of stale news episodes piling up? Set a freshness limit '
                        'per podcast. A daily news show? Set it to 2 days. A weekly '
                        'deep-dive? Two weeks. Or leave it off entirely — it\'s up to you.',
                  ),
                  _AddFirstPodcastPage(
                    onPodcastAdded: () =>
                        setState(() => _hasAddedPodcast = true),
                  ),
                  const _OnboardingPage(
                    icon: Icons.check_circle_outline,
                    title: 'You\'re all set',
                    body:
                        'You can revisit any of these settings at any time from the '
                        'Settings screen.',
                  ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.all(24),
              child: Row(
                children: [
                  if (_currentPage > 0)
                    IconButton(
                      icon: const Icon(Icons.arrow_back),
                      tooltip: 'Previous page',
                      onPressed: () => _pageController.previousPage(
                        duration: const Duration(milliseconds: 300),
                        curve: Curves.easeInOut,
                      ),
                    ),
                  const Spacer(),
                  if (_currentPage < _totalPages - 1)
                    FilledButton(
                      onPressed: (_currentPage == 5 && !_hasAddedPodcast)
                          ? null
                          : _nextPage,
                      child: const Text('Next'),
                    )
                  else
                    FilledButton(
                      onPressed: _finish,
                      child: const Text('Start Listening'),
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  void _nextPage() {
    _pageController.nextPage(
      duration: const Duration(milliseconds: 300),
      curve: Curves.easeInOut,
    );
  }

  Future<void> _finish() async {
    final db = ref.read(appDatabaseProvider);
    await AppSettingsRepositoryImpl(
      database: db,
    ).setOnboardingComplete(complete: true);
    if (mounted) Navigator.of(context).pop();
  }
}

class _OnboardingPage extends StatelessWidget {
  const _OnboardingPage({
    required this.icon,
    required this.title,
    required this.body,
  });

  final IconData icon;
  final String title;
  final String body;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 32),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(
            icon,
            size: 80,
            color: Theme.of(context).colorScheme.primary,
            semanticLabel: '',
          ),
          const SizedBox(height: 32),
          Semantics(
            header: true,
            child: Text(
              title,
              style: Theme.of(context).textTheme.headlineSmall,
              textAlign: TextAlign.center,
            ),
          ),
          const SizedBox(height: 16),
          Text(
            body,
            style: Theme.of(context).textTheme.bodyLarge?.copyWith(
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
            textAlign: TextAlign.center,
          ),
        ],
      ),
    );
  }
}

class _PrivacyPage extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 32),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(
            Icons.lock_outline,
            size: 80,
            color: Theme.of(context).colorScheme.primary,
            semanticLabel: '',
          ),
          const SizedBox(height: 32),
          Semantics(
            header: true,
            child: Text(
              'Your Privacy',
              style: Theme.of(context).textTheme.headlineSmall,
              textAlign: TextAlign.center,
            ),
          ),
          const SizedBox(height: 16),
          Text(
            'Earshot collects crash reports and anonymous usage data to improve '
            'the app. Both are opt-out. Your listening history stays on your '
            'device and is never shared. You control how long it\'s kept.',
            style: Theme.of(context).textTheme.bodyLarge?.copyWith(
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 24),
          Text(
            'You can change all privacy settings at any time in Settings → Privacy.',
            style: Theme.of(context).textTheme.bodyMedium,
            textAlign: TextAlign.center,
          ),
        ],
      ),
    );
  }
}

class _AddFirstPodcastPage extends ConsumerWidget {
  const _AddFirstPodcastPage({required this.onPodcastAdded});

  final VoidCallback onPodcastAdded;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 32),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(
            Icons.podcasts,
            size: 80,
            color: Theme.of(context).colorScheme.primary,
            semanticLabel: '',
          ),
          const SizedBox(height: 32),
          Semantics(
            header: true,
            child: Text(
              'Add your first podcast',
              style: Theme.of(context).textTheme.headlineSmall,
              textAlign: TextAlign.center,
            ),
          ),
          const SizedBox(height: 16),
          Text(
            'Search for a podcast, paste an RSS URL, or import an OPML file.',
            style: Theme.of(context).textTheme.bodyLarge?.copyWith(
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 32),
          FilledButton.icon(
            icon: const Icon(Icons.search),
            label: const Text('Search podcasts'),
            onPressed: () async {
              await Navigator.of(context).push<void>(
                MaterialPageRoute<void>(builder: (_) => const SearchScreen()),
              );
              onPodcastAdded();
            },
          ),
          const SizedBox(height: 12),
          OutlinedButton.icon(
            icon: const Icon(Icons.link),
            label: const Text('Add by RSS URL'),
            onPressed: () async {
              await Navigator.of(context).push<void>(
                MaterialPageRoute<void>(
                  builder: (_) => const AddPodcastScreen(),
                ),
              );
              onPodcastAdded();
            },
          ),
        ],
      ),
    );
  }
}
