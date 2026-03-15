import 'package:flutter_test/flutter_test.dart';

import 'package:territory_game/main.dart';

void main() {
  testWidgets('Home screen shows start button', (WidgetTester tester) async {
    await tester.pumpWidget(const TerritoryGameApp());

    expect(find.text('Start'), findsOneWidget);
  });
}
