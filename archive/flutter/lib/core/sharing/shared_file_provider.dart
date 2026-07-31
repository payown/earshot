import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'sharing_intent_gateway.dart';

/// Files the app was launched with (cold start), via "Open in Earshot" or
/// "Share to Earshot". Overridden with a real value in `main.dart`.
final initialSharedOpmlPathsProvider = Provider<List<String>>((_) => const []);

/// Queue of OPML file paths shared/opened from other apps, pending import.
///
/// Seeded from [initialSharedOpmlPathsProvider] on cold start. New files
/// shared while the app is running are appended via [sharingIntentGatewayProvider]'s
/// stream. [OpmlImportScreen] drains this queue with [takeNext].
final sharedOpmlFilesProvider = NotifierProvider<SharedFileQueue, List<String>>(
  SharedFileQueue.new,
);

class SharedFileQueue extends Notifier<List<String>> {
  @override
  List<String> build() {
    final initial = ref.read(initialSharedOpmlPathsProvider);
    final subscription = ref
        .read(sharingIntentGatewayProvider)
        .sharedFileStream
        .listen((paths) {
          if (paths.isNotEmpty) state = [...state, ...paths];
        });
    ref.onDispose(subscription.cancel);
    return initial;
  }

  /// Dequeues the next path for sequential import, or null if empty.
  String? takeNext() {
    if (state.isEmpty) return null;
    final next = state.first;
    state = state.sublist(1);
    return next;
  }
}
