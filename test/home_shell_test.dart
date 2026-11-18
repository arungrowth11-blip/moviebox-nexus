import 'package:flutter_test/flutter_test.dart';
import 'package:moviebox_nexus/main.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  testWidgets('MovieBox home shell renders before deferred startup work', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    await tester.pumpWidget(const MovieBoxApp());

    expect(find.text('MOVIEBOX '), findsOneWidget);
    expect(find.text('Home'), findsOneWidget);
  });
}
