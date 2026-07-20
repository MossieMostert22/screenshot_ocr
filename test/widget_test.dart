import 'package:flutter_test/flutter_test.dart';

import 'package:screenshot_ocr/main.dart';

void main() {
  testWidgets('renders the OCR dashboard UI', (WidgetTester tester) async {
    await tester.pumpWidget(const MyApp());

    expect(find.text('Instant Screenshot OCR'), findsOneWidget);
    expect(find.text('Auto-copy to clipboard'), findsOneWidget);
    expect(find.text('Stitch & Scroll OCR'), findsOneWidget);
    expect(find.text('No scans captured yet'), findsOneWidget);
  });
}
