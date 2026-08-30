import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gravity_torrent/l10n/app_localizations.dart';
import 'package:gravity_torrent/screens/settings/dialogs/peer_port.dart';

void main() {
  group('PeerPortDialog Unit & Widget Validation Tests', () {
    Widget buildTestWidget({
      required int currentValue,
      required void Function(int) onSave,
    }) {
      return MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(
          body: PeerPortDialog(
            currentValue: currentValue,
            onSave: onSave,
          ),
        ),
      );
    }

    testWidgets('displays initial valid port value', (tester) async {
      await tester.pumpWidget(buildTestWidget(
        currentValue: 6881,
        onSave: (_) {},
      ),);
      await tester.pumpAndSettle();

      expect(find.text('6881'), findsOneWidget);
    });

    testWidgets('defaults to 51413 when initial currentValue is 0 or non-positive', (tester) async {
      await tester.pumpWidget(buildTestWidget(
        currentValue: 0,
        onSave: (_) {},
      ),);
      await tester.pumpAndSettle();

      expect(find.text('51413'), findsOneWidget);
    });

    testWidgets('defaults to 51413 when initial currentValue is negative', (tester) async {
      await tester.pumpWidget(buildTestWidget(
        currentValue: -1,
        onSave: (_) {},
      ),);
      await tester.pumpAndSettle();

      expect(find.text('51413'), findsOneWidget);
    });

    testWidgets('rejects empty input with emptyNumber validation error', (tester) async {
      int? savedPort;
      await tester.pumpWidget(buildTestWidget(
        currentValue: 6881,
        onSave: (p) => savedPort = p,
      ),);
      await tester.pumpAndSettle();

      final textField = find.byType(TextFormField);
      await tester.enterText(textField, '');
      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();

      expect(savedPort, isNull);
      expect(find.text('Please enter a number'), findsOneWidget);
    });

    testWidgets('rejects port 0 (< 1) with invalidNumber validation error', (tester) async {
      int? savedPort;
      await tester.pumpWidget(buildTestWidget(
        currentValue: 6881,
        onSave: (p) => savedPort = p,
      ),);
      await tester.pumpAndSettle();

      final textField = find.byType(TextFormField);
      await tester.enterText(textField, '0');
      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();

      expect(savedPort, isNull);
      expect(find.text('Please enter a valid number'), findsOneWidget);
    });

    testWidgets('rejects port 65536 (> 65535) with invalidNumber validation error', (tester) async {
      int? savedPort;
      await tester.pumpWidget(buildTestWidget(
        currentValue: 6881,
        onSave: (p) => savedPort = p,
      ),);
      await tester.pumpAndSettle();

      final textField = find.byType(TextFormField);
      await tester.enterText(textField, '65536');
      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();

      expect(savedPort, isNull);
      expect(find.text('Please enter a valid number'), findsOneWidget);
    });

    testWidgets('rejects out-of-range port 70000 and 99999', (tester) async {
      int? savedPort;
      await tester.pumpWidget(buildTestWidget(
        currentValue: 6881,
        onSave: (p) => savedPort = p,
      ),);
      await tester.pumpAndSettle();

      final textField = find.byType(TextFormField);
      await tester.enterText(textField, '70000');
      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();

      expect(savedPort, isNull);
      expect(find.text('Please enter a valid number'), findsOneWidget);

      await tester.enterText(textField, '99999');
      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();

      expect(savedPort, isNull);
      expect(find.text('Please enter a valid number'), findsOneWidget);
    });

    testWidgets('accepts valid lower bound port 1', (tester) async {
      int? savedPort;
      await tester.pumpWidget(buildTestWidget(
        currentValue: 6881,
        onSave: (p) => savedPort = p,
      ),);
      await tester.pumpAndSettle();

      final textField = find.byType(TextFormField);
      await tester.enterText(textField, '1');
      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();

      expect(savedPort, equals(1));
    });

    testWidgets('accepts valid upper bound port 65535', (tester) async {
      int? savedPort;
      await tester.pumpWidget(buildTestWidget(
        currentValue: 6881,
        onSave: (p) => savedPort = p,
      ),);
      await tester.pumpAndSettle();

      final textField = find.byType(TextFormField);
      await tester.enterText(textField, '65535');
      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();

      expect(savedPort, equals(65535));
    });

    testWidgets('accepts standard peer port 51413 and saves correctly', (tester) async {
      int? savedPort;
      await tester.pumpWidget(buildTestWidget(
        currentValue: 6881,
        onSave: (p) => savedPort = p,
      ),);
      await tester.pumpAndSettle();

      final textField = find.byType(TextFormField);
      await tester.enterText(textField, '51413');
      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();

      expect(savedPort, equals(51413));
    });

    testWidgets('cancels dialog without calling onSave', (tester) async {
      int? savedPort;
      await tester.pumpWidget(buildTestWidget(
        currentValue: 6881,
        onSave: (p) => savedPort = p,
      ),);
      await tester.pumpAndSettle();

      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();

      expect(savedPort, isNull);
    });
  });
}
