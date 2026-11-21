import 'package:builddemo/main.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('shows the build environment', (tester) async {
    await tester.pumpWidget(const BuildDemoApp());
    expect(find.text('LOCAL'), findsOneWidget);
  });
}
