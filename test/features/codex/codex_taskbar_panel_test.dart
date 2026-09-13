import 'dart:ui';

import 'package:fl_clash/features/codex/codex_taskbar_panel.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('recognizes the isolated taskbar panel entrypoint', () {
    expect(isCodexTaskbarPanel([codexTaskbarPanelArgument]), isTrue);
    expect(isCodexTaskbarPanel([codexTaskbarPanelPreviewArgument]), isTrue);
    expect(
      isCodexTaskbarPanelPreview([codexTaskbarPanelPreviewArgument]),
      isTrue,
    );
    expect(isCodexTaskbarPanel(const []), isFalse);
  });

  test('centers the collapsed pill inside the monitor taskbar strip', () {
    final position = codexTaskbarPanelPosition(
      workArea: const Rect.fromLTWH(0, 0, 1920, 1080),
      panelSize: const Size(360, 36),
      height: 36,
      inset: 8,
    );

    expect(position, const Offset(780, 1036));
  });

  test('centers the expanded popup and persistent pill as one group', () {
    final position = codexTaskbarPanelPosition(
      workArea: const Rect.fromLTWH(0, 0, 1920, 1080),
      panelSize: const Size(360, 160),
      height: 160,
      inset: 8,
    );

    expect(position, const Offset(780, 912));
  });

  test('keeps a remembered position inside the full monitor bounds', () {
    final position = codexTaskbarPanelClampPosition(
      workArea: const Rect.fromLTWH(0, 0, 1920, 1080),
      panelSize: const Size(360, 160),
      position: const Offset(1800, 1000),
      inset: 8,
    );

    expect(position, const Offset(1552, 912));
  });
}
