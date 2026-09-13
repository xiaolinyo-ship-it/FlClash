import 'dart:ui';

import 'package:fl_clash/features/codex/codex_taskbar_panel.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('recognizes the isolated taskbar panel entrypoint', () {
    expect(isCodexTaskbarPanel([codexTaskbarPanelArgument]), isTrue);
    expect(isCodexTaskbarPanel(const []), isFalse);
  });

  test('centers the collapsed pill above the work-area taskbar', () {
    final position = codexTaskbarPanelPosition(
      workArea: const Rect.fromLTWH(0, 0, 1920, 1080),
      panelSize: const Size(196, 24),
      height: 24,
      inset: 12,
    );

    expect(position, const Offset(862, 1044));
  });

  test('centers the expanded popup and persistent pill as one group', () {
    final position = codexTaskbarPanelPosition(
      workArea: const Rect.fromLTWH(0, 0, 1920, 1080),
      panelSize: const Size(324, 140),
      height: 140,
      inset: 12,
    );

    expect(position, const Offset(798, 928));
  });

  test('keeps a remembered position inside the work area', () {
    final position = codexTaskbarPanelClampPosition(
      workArea: const Rect.fromLTWH(0, 0, 1920, 1040),
      panelSize: const Size(324, 150),
      position: const Offset(1800, 1000),
      inset: 12,
    );

    expect(position, const Offset(1584, 878));
  });
}
