import 'dart:async';

import 'package:earshot/core/sharing/shared_file_provider.dart';
import 'package:earshot/core/sharing/sharing_intent_gateway.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

class _FakeGateway implements SharingIntentGateway {
  final _controller = StreamController<List<String>>.broadcast();

  @override
  Future<List<String>> getInitialSharedFiles() async => const [];

  @override
  Stream<List<String>> get sharedFileStream => _controller.stream;

  void emit(List<String> paths) => _controller.add(paths);

  void dispose() => _controller.close();
}

void main() {
  group('SharedFileQueue', () {
    test('seeds initial state from initialSharedOpmlPathsProvider', () {
      final gateway = _FakeGateway();
      final container = ProviderContainer(
        overrides: [
          initialSharedOpmlPathsProvider.overrideWithValue(['a.opml']),
          sharingIntentGatewayProvider.overrideWithValue(gateway),
        ],
      );
      addTearDown(container.dispose);
      addTearDown(gateway.dispose);

      expect(container.read(sharedOpmlFilesProvider), ['a.opml']);
    });

    test('takeNext dequeues in order and returns null when empty', () {
      final gateway = _FakeGateway();
      final container = ProviderContainer(
        overrides: [
          initialSharedOpmlPathsProvider.overrideWithValue([
            'a.opml',
            'b.opml',
          ]),
          sharingIntentGatewayProvider.overrideWithValue(gateway),
        ],
      );
      addTearDown(container.dispose);
      addTearDown(gateway.dispose);

      final queue = container.read(sharedOpmlFilesProvider.notifier);

      expect(queue.takeNext(), 'a.opml');
      expect(queue.takeNext(), 'b.opml');
      expect(queue.takeNext(), isNull);
    });

    test('appends files shared while running via the stream', () async {
      final gateway = _FakeGateway();
      final container = ProviderContainer(
        overrides: [
          initialSharedOpmlPathsProvider.overrideWithValue(['a.opml']),
          sharingIntentGatewayProvider.overrideWithValue(gateway),
        ],
      );
      addTearDown(container.dispose);
      addTearDown(gateway.dispose);

      // Build the notifier so its stream listener attaches.
      expect(container.read(sharedOpmlFilesProvider), ['a.opml']);

      gateway.emit(['b.opml']);
      await Future<void>.delayed(Duration.zero);

      expect(container.read(sharedOpmlFilesProvider), ['a.opml', 'b.opml']);
    });

    test('ignores empty stream emissions', () async {
      final gateway = _FakeGateway();
      final container = ProviderContainer(
        overrides: [
          initialSharedOpmlPathsProvider.overrideWithValue(['a.opml']),
          sharingIntentGatewayProvider.overrideWithValue(gateway),
        ],
      );
      addTearDown(container.dispose);
      addTearDown(gateway.dispose);

      expect(container.read(sharedOpmlFilesProvider), ['a.opml']);

      gateway.emit(const []);
      await Future<void>.delayed(Duration.zero);

      expect(container.read(sharedOpmlFilesProvider), ['a.opml']);
    });
  });
}
