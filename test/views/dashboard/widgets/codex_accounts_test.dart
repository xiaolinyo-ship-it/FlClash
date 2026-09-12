import 'dart:io';

import 'package:fl_clash/features/codex/codex_account_snapshot.dart';
import 'package:fl_clash/l10n/l10n.dart';
import 'package:fl_clash/views/dashboard/widgets/codex_accounts.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../../helpers/test_app.dart';

const _fixturePath = 'test/fixtures/codex/snapshots_three_accounts.json';

Future<String> _fixture() => File(_fixturePath).readAsString();

Future<void> _pumpLoaded(WidgetTester tester) async {
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 300));
}

CodexAccountSnapshotReader _reader({
  required String contents,
  Future<String> Function()? readText,
}) {
  return CodexAccountSnapshotReader(
    readText: readText ?? () async => contents,
    clock: () => DateTime(2026, 9, 12, 17),
  );
}

void main() {
  testWidgets('renders three stable account cards and independent quotas', (
    tester,
  ) async {
    final contents = await _fixture();
    tester.view.physicalSize = const Size(1200, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      TestApp(
        child: SingleChildScrollView(
          child: CodexAccounts(
            reader: _reader(contents: contents),
            isWindows: true,
          ),
        ),
      ),
    );
    await _pumpLoaded(tester);

    expect(find.text(AppLocalizations.current.codexAccounts), findsOneWidget);
    expect(find.text('al***@example.invalid'), findsOneWidget);
    expect(find.text('be***@example.invalid'), findsOneWidget);
    expect(find.text('ga***@example.invalid'), findsOneWidget);
    expect(
      find.text(AppLocalizations.current.codexUsedRemaining('25%', '75%')),
      findsOneWidget,
    );
    expect(
      find.text(AppLocalizations.current.codexUsedRemaining('40%', '60%')),
      findsOneWidget,
    );
    expect(
      find.text(AppLocalizations.current.codexUsedRemaining('100%', '0%')),
      findsOneWidget,
    );
    expect(
      find.text(AppLocalizations.current.codexUsedRemaining('55%', '45%')),
      findsOneWidget,
    );
    expect(
      find.text(AppLocalizations.current.codexDataAnomaly),
      findsNWidgets(3),
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('refresh rereads the snapshot without changing the card mapping', (
    tester,
  ) async {
    final contents = await _fixture();
    var reads = 0;
    final reader = _reader(
      contents: contents,
      readText: () async {
        reads++;
        return contents;
      },
    );

    await tester.pumpWidget(
      TestApp(
        child: CodexAccounts(
          reader: reader,
          isWindows: true,
        ),
      ),
    );
    await _pumpLoaded(tester);
    expect(reads, 1);

    await tester.tap(find.byIcon(Icons.refresh));
    await _pumpLoaded(tester);

    expect(reads, 2);
    expect(find.text('al***@example.invalid'), findsOneWidget);
    expect(find.text('be***@example.invalid'), findsOneWidget);
    expect(find.text('ga***@example.invalid'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('fits a narrow dashboard without overflow', (tester) async {
    final contents = await _fixture();
    tester.view.physicalSize = const Size(480, 1200);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      TestApp(
        child: SingleChildScrollView(
          child: CodexAccounts(
            reader: _reader(contents: contents),
            isWindows: true,
          ),
        ),
      ),
    );
    await _pumpLoaded(tester);

    expect(find.text('al***@example.invalid'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
