import 'package:flutter_test/flutter_test.dart';

import 'package:continium/main.dart';
import 'package:continium/services/websocket_service.dart';

void main() {
  testWidgets('App boots and shows the Connexion panel', (tester) async {
    await tester.pumpWidget(const ContinuumApp());
    await tester.pump();

    expect(find.text('Connexion'), findsWidgets);
    expect(find.byType(WebSocketService), findsNothing);
  });
}
