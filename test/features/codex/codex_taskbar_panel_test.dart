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
      panelSize: const Size(240, 26),
      height: 26,
      inset: 12,
    );

    expect(position, const Offset(840, 1042));
  });

  test('centers the expanded popup over the same pill anchor', () {
    final position = codexTaskbarPanelPosition(
      workArea: const Rect.fromLTWH(0, 0, 1920, 1080),
      panelSize: const Size(324, 112),
      height: 112,
      inset: 12,
    );

    expect(position, const Offset(798, 956));
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
