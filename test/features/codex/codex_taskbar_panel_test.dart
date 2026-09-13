import 'dart:io';
import 'dart:ui';

import 'package:fl_clash/features/codex/codex_account_snapshot.dart';
import 'package:fl_clash/features/codex/codex_taskbar_panel.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('recognizes the isolated taskbar panel entrypoint', () {
    expect(isCodexTaskbarPanel([codexTaskbarPanelArgument]), isTrue);
    expect(isCodexTaskbarPanel(const []), isFalse);
  });

  test('centers the panel above the work-area taskbar', () {
    final position = codexTaskbarPanelPosition(
      workArea: const Rect.fromLTWH(0, 0, 1920, 1080),
      panelSize: const Size(660, 40),
      height: 40,
      inset: 12,
    );

    expect(position, const Offset(630, 1028));
  });

  test('keeps a remembered position inside the work area', () {
    final position = codexTaskbarPanelClampPosition(
      workArea: const Rect.fromLTWH(0, 0, 1920, 1040),
      panelSize: const Size(660, 150),
      position: const Offset(1800, 1000),
      inset: 12,
    );

    expect(position, const Offset(1248, 878));
  });

  testWidgets('renders each account with its own 5h and weekly values', (
    tester,
  ) async {
    final raw = await File(
      'test/fixtures/codex/snapshots_three_accounts.json',
    ).readAsString();
    final reader = CodexAccountSnapshotReader(
      readText: () async => raw,
      clock: () => DateTime(2026, 9, 12, 17),
    );

    await tester.pumpWidget(
      MaterialApp(
        home: CodexTaskbarPanel(
          reader: reader,
          initiallyExpanded: true,
          clock: () => DateTime(2026, 9, 12, 17),
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    expect(find.text('al***@example.invalid'), findsOneWidget);
    expect(find.text('be***@example.invalid'), findsOneWidget);
    expect(find.text('ga***@example.invalid'), findsOneWidget);
    final values = tester
        .widgetList<RichText>(find.byType(RichText))
        .map((richText) => richText.text.toPlainText())
        .toList();
    expect(
      values,
      contains(
        predicate<String>(
          (value) =>
              value.contains('al***@example.invalid') &&
              value.contains('5h 75%') &&
              value.contains('W 60%'),
        ),
      ),
    );
    expect(
      values,
      contains(
        predicate<String>(
          (value) =>
              value.contains('ga***@example.invalid') &&
              value.contains('5h -') &&
              value.contains('W -'),
        ),
      ),
    );
  });
}
