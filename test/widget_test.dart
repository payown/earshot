import 'package:earshot/main.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('WelcomeScreen shows accessible heading', (tester) async {
    await tester.pumpWidget(
      const ProviderScope(child: EarshotApp()),
    );

    expect(find.text('Welcome to Earshot'), findsOneWidget);

    expect(
      tester.getSemantics(find.text('Welcome to Earshot')),
      matchesSemantics(isHeader: true, label: 'Welcome to Earshot'),
    );
  });
}
