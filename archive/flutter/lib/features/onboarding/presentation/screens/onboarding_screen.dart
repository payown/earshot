import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:go_router/go_router.dart';

import '../../../../core/providers/core_providers.dart';
import '../../../../core/router/app_router.dart';
import '../../../../features/settings/data/app_settings_repository.dart';

class OnboardingScreen extends ConsumerStatefulWidget {
  const OnboardingScreen({this.replayMode = false, super.key});

  /// When true, this screen replays the tutorial from Settings. Finishing
  /// just pops back to Settings instead of marking onboarding complete.
  final bool replayMode;

  @override
  ConsumerState<OnboardingScreen> createState() => _OnboardingScreenState();
}

class _OnboardingScreenState extends ConsumerState<OnboardingScreen> {
  final _pageController = PageController();
  // One per page, except the last ("You're all set"), whose default VoiceOver
  // focus order was already correct.
  final List<FocusNode> _headingFocusNodes = List.generate(
    6,
    (_) => FocusNode(debugLabel: 'onboarding-heading'),
  );
  int _currentPage = 0;
  bool _hasAddedPodcast = false;

  static const _totalPages = 7;

  @override
  void initState() {
    super.initState();
    // Without this, VoiceOver's accessibility focus lands on the Next button
    // on first load, so forward swipes skip the page content entirely.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _headingFocusNodes[0].requestFocus();
    });
  }

  @override
  void dispose() {
    _pageController.dispose();
    for (final node in _headingFocusNodes) {
      node.dispose();
    }
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
                onPageChanged: (i) {
                  setState(() => _currentPage = i);
                  const titles = [
                    'Welcome to Earshot',
                    'How your content flows',
                    'Your Privacy',
                    'Quick Actions',
                    'Queue expiration',
                    'Add your first podcast',
                    "You're all set",
                  ];
                  final title = i < titles.length ? titles[i] : '';
                  SemanticsService.sendAnnouncement(
                    View.of(context),
                    'Page ${i + 1} of $_totalPages: $title',
                    TextDirection.ltr,
                  );
                  // Move VoiceOver focus to the new page's heading so forward
                  // swipes move through its content, not back to the Next
                  // button left over from the previous page.
                  if (i < _headingFocusNodes.length) {
                    WidgetsBinding.instance.addPostFrameCallback((_) {
                      if (!mounted) return;
                      _headingFocusNodes[i].requestFocus();
                    });
                  }
                },
                children: [
                  _OnboardingPage(
                    icon: Icons.headphones,
                    title: 'Welcome to Earshot',
                    body: 'A podcast player built for the way you listen.',
                    headingFocusNode: _headingFocusNodes[0],
                  ),
                  _OnboardingPage(
                    icon: Icons.move_down,
                    title: 'How your content flows',
                    body:
                        'Follow a podcast, and new episodes arrive in your Inbox. '
                        'Triage them into your Queue when you\'re ready to listen. '
                        'Mark a podcast as Auto-Queue and new episodes skip Inbox entirely.',
                    headingFocusNode: _headingFocusNodes[1],
                  ),
                  _PrivacyPage(headingFocusNode: _headingFocusNodes[2]),
                  _OnboardingPage(
                    icon: Icons.swipe_up_alt,
                    title: 'Quick Actions',
                    body:
                        'Every episode and podcast has Quick Actions — shortcuts you can '
                        'reorder to match how you listen. On a screen reader, swipe up '
                        'or down to access them. You can customize the order in Settings.',
                    headingFocusNode: _headingFocusNodes[3],
                  ),
                  _OnboardingPage(
                    icon: Icons.timer_off,
                    title: 'Queue expiration',
                    body:
                        'Tired of stale news episodes piling up? Set a freshness limit '
                        'per podcast. A daily news show? Set it to 2 days. A weekly '
                        'deep-dive? Two weeks. Or leave it off entirely — it\'s up to you.',
                    headingFocusNode: _headingFocusNodes[4],
                  ),
                  _AddFirstPodcastPage(
                    onPodcastAdded: () {
                      setState(() => _hasAddedPodcast = true);
                      _nextPage();
                    },
                    headingFocusNode: _headingFocusNodes[5],
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
                    Semantics(
                      enabled:
                          _currentPage != 5 ||
                          _hasAddedPodcast ||
                          widget.replayMode,
                      hint:
                          (_currentPage == 5 &&
                              !_hasAddedPodcast &&
                              !widget.replayMode)
                          ? 'Add a podcast first to continue'
                          : null,
                      child: FilledButton(
                        onPressed:
                            (_currentPage == 5 &&
                                !_hasAddedPodcast &&
                                !widget.replayMode)
                            ? null
                            : _nextPage,
                        child: const Text('Next'),
                      ),
                    )
                  else
                    FilledButton(
                      onPressed: _finish,
                      child: Text(
                        widget.replayMode ? 'Done' : 'Start Listening',
                      ),
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
    if (widget.replayMode) {
      if (!mounted) return;
      // Pop back to wherever Settings is on the stack. Fall back to
      // navigating there directly in case /tutorial was ever reached
      // without Settings beneath it (e.g. a future deep link).
      if (context.canPop()) {
        context.pop();
      } else {
        context.go(AppRoutes.settings);
      }
      return;
    }
    final db = ref.read(appDatabaseProvider);
    await AppSettingsRepositoryImpl(
      database: db,
    ).setOnboardingComplete(complete: true);
    // Invalidate the cached onboarding state so the router redirect re-fires.
    ref.invalidate(isOnboardingCompleteProvider);
    if (mounted) context.go(AppRoutes.subscriptions);
  }
}

class _OnboardingPage extends StatelessWidget {
  const _OnboardingPage({
    required this.icon,
    required this.title,
    required this.body,
    this.headingFocusNode,
  });

  final IconData icon;
  final String title;
  final String body;

  /// When set, VoiceOver/TalkBack focus is moved to this page's heading on
  /// page change so forward swipes traverse the page content.
  final FocusNode? headingFocusNode;

  @override
  Widget build(BuildContext context) {
    final heading = Semantics(
      header: true,
      label: title,
      child: ExcludeSemantics(
        child: Text(
          title,
          style: Theme.of(context).textTheme.headlineSmall,
          textAlign: TextAlign.center,
        ),
      ),
    );
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 32),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(
            icon,
            size: 80,
            color: Theme.of(context).colorScheme.primary,
          ),
          const SizedBox(height: 32),
          headingFocusNode == null
              ? heading
              : Focus(
                  focusNode: headingFocusNode,
                  // Reachable via requestFocus() for screen readers, but not
                  // a Tab/arrow-key stop for hardware-keyboard users since it
                  // wraps inert heading text.
                  skipTraversal: true,
                  child: heading,
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
  const _PrivacyPage({this.headingFocusNode});

  /// When set, VoiceOver/TalkBack focus is moved to this page's heading on
  /// page change so forward swipes traverse the page content.
  final FocusNode? headingFocusNode;

  @override
  Widget build(BuildContext context) {
    final heading = Semantics(
      header: true,
      label: 'Your Privacy',
      child: ExcludeSemantics(
        child: Text(
          'Your Privacy',
          style: Theme.of(context).textTheme.headlineSmall,
          textAlign: TextAlign.center,
        ),
      ),
    );
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 32),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(
            Icons.lock_outline,
            size: 80,
            color: Theme.of(context).colorScheme.primary,
          ),
          const SizedBox(height: 32),
          headingFocusNode == null
              ? heading
              : Focus(
                  focusNode: headingFocusNode,
                  // Reachable via requestFocus() for screen readers, but not
                  // a Tab/arrow-key stop for hardware-keyboard users since it
                  // wraps inert heading text.
                  skipTraversal: true,
                  child: heading,
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
  const _AddFirstPodcastPage({
    required this.onPodcastAdded,
    this.headingFocusNode,
  });

  final VoidCallback onPodcastAdded;

  /// When set, VoiceOver/TalkBack focus is moved to this page's heading on
  /// page change so forward swipes traverse the page content.
  final FocusNode? headingFocusNode;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final heading = Semantics(
      header: true,
      label: 'Add your first podcast',
      child: ExcludeSemantics(
        child: Text(
          'Add your first podcast',
          style: Theme.of(context).textTheme.headlineSmall,
          textAlign: TextAlign.center,
        ),
      ),
    );
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 32),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(
            Icons.podcasts,
            size: 80,
            color: Theme.of(context).colorScheme.primary,
          ),
          const SizedBox(height: 32),
          headingFocusNode == null
              ? heading
              : Focus(
                  focusNode: headingFocusNode,
                  // Reachable via requestFocus() for screen readers, but not
                  // a Tab/arrow-key stop for hardware-keyboard users since it
                  // wraps inert heading text.
                  skipTraversal: true,
                  child: heading,
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
              final done = await context.push<bool>(
                AppRoutes.search,
                extra: true,
              );
              if (done == true) onPodcastAdded();
            },
          ),
          const SizedBox(height: 12),
          OutlinedButton.icon(
            icon: const Icon(Icons.link),
            label: const Text('Add by RSS URL'),
            onPressed: () async {
              final done = await context.push<bool>(
                AppRoutes.addPodcast,
                extra: true,
              );
              if (done == true) onPodcastAdded();
            },
          ),
          const SizedBox(height: 12),
          OutlinedButton.icon(
            icon: const Icon(Icons.upload_file),
            label: const Text('Import OPML'),
            onPressed: () async {
              final done = await context.push<bool>(
                AppRoutes.settingsImportOpml,
                extra: true,
              );
              if (done == true) onPodcastAdded();
            },
          ),
        ],
      ),
    );
  }
}
