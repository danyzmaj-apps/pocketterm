import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pocketterm_core/ui.dart';

void main() {
  for (final t in [PtTheme.mocha, PtTheme.dawn, PtTheme.tokyoNight, PtTheme.gruvbox]) {
    testWidgets(
      '${t.name}: a picked chip is filled with the accent, an unpicked one is an outlined field, sent or not',
      (tester) async {
        Future<void> show({required bool enabled}) => tester.pumpWidget(
          MaterialApp(
            theme: appTheme(t),
            home: Scaffold(
              body: Row(
                children: [
                  for (final picked in [true, false])
                    ChoiceChip(
                      key: ValueKey(picked),
                      label: Text('$picked'),
                      selected: picked,
                      onSelected: enabled ? (_) {} : null,
                    ),
                ],
              ),
            ),
          ),
        );

        ({Color fill, Color label, Color border}) looks({required bool picked}) {
          final chip = find.byKey(ValueKey(picked));
          final decoration =
              tester.widget<Ink>(find.descendant(of: chip, matching: find.byType(Ink))).decoration! as ShapeDecoration;
          return (
            fill: decoration.color!,
            label: tester
                .widget<RichText>(find.descendant(of: chip, matching: find.byType(RichText)))
                .text
                .style!
                .color!,
            border: (decoration.shape as OutlinedBorder).side.color,
          );
        }

        for (final enabled in [true, false]) {
          await show(enabled: enabled);
          await tester.pumpAndSettle();
          final picked = looks(picked: true);
          final unpicked = looks(picked: false);
          expect(picked.fill, t.accent, reason: 'enabled: $enabled');
          expect(picked.label, t.onAccent, reason: 'enabled: $enabled');
          expect(unpicked.fill, t.field, reason: 'enabled: $enabled');
          expect(unpicked.border, t.line2, reason: 'enabled: $enabled');
          expect(unpicked.label, isNot(t.onAccent), reason: 'enabled: $enabled');
        }
      },
    );
  }
}
