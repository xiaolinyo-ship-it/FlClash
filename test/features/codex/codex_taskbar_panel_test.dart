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
      panelSize: const Size(420, 40),
      height: 40,
      inset: 12,
    );

    expect(position, const Offset(750, 1028));
  });

  test('centers the expanded popup over the same pill anchor', () {
    final position = codexTaskbarPanelPosition(
      workArea: const Rect.fromLTWH(0, 0, 1920, 1080),
      panelSize: const Size(660, 126),
      height: 126,
      inset: 12,
    );

    expect(position, const Offset(630, 942));
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
}
