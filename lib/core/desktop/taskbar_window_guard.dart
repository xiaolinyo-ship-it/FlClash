import 'dart:async';
import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';

const _panelTitle = 'FlClash Codex Panel';
const _pollInterval = Duration(milliseconds: 120);

/// Reasserts the panel's topmost z-order while it overlaps the Windows taskbar.
///
/// Windows may reorder the taskbar above an overlapping topmost tool window
/// when the shell activates it. This guard only changes z-order and never
/// activates, moves, resizes, or closes the panel.
abstract final class TaskbarWindowGuard {
  static Timer? _timer;
  static _WindowsTaskbarApi? _api;

  static void start() {
    if (!Platform.isWindows || _timer != null) {
      return;
    }
    _reassertIfNeeded();
    _timer = Timer.periodic(_pollInterval, (_) => _reassertIfNeeded());
  }

  static void _reassertIfNeeded() {
    try {
      final api = _api ??= _WindowsTaskbarApi();
      final panel = api.findPanel();
      if (panel == 0 || api.isWindowVisible(panel) == 0) {
        return;
      }
      final panelRect = api.windowRect(panel);
      if (panelRect == null ||
          !api.taskbarRects().any(panelRect.overlaps)) {
        return;
      }
      api.setTopmost(panel);
    } catch (_) {
      // A shell window can disappear during a taskbar transition. The next
      // timer tick retries without affecting the panel or proxy core.
    }
  }
}

final class _NativeRect extends Struct {
  @Int32()
  external int left;

  @Int32()
  external int top;

  @Int32()
  external int right;

  @Int32()
  external int bottom;
}

final class _RectSnapshot {
  final int left;
  final int top;
  final int right;
  final int bottom;

  const _RectSnapshot(this.left, this.top, this.right, this.bottom);

  bool overlaps(_RectSnapshot other) =>
      left < other.right &&
      right > other.left &&
      top < other.bottom &&
      bottom > other.top;
}

final class _WindowsTaskbarApi {
  _WindowsTaskbarApi() : _user32 = DynamicLibrary.open('user32.dll') {
    _findWindow = _user32.lookupFunction<
        IntPtr Function(Pointer<Utf16>, Pointer<Utf16>),
        int Function(Pointer<Utf16>, Pointer<Utf16>)
      >('FindWindowW');
    _findWindowEx = _user32.lookupFunction<
        IntPtr Function(IntPtr, IntPtr, Pointer<Utf16>, Pointer<Utf16>),
        int Function(int, int, Pointer<Utf16>, Pointer<Utf16>)
      >('FindWindowExW');
    _getWindowRect = _user32.lookupFunction<
        Int32 Function(IntPtr, Pointer<_NativeRect>),
        int Function(int, Pointer<_NativeRect>)
      >('GetWindowRect');
    _isWindowVisible = _user32.lookupFunction<
        Int32 Function(IntPtr),
        int Function(int)
      >('IsWindowVisible');
    _setWindowPos = _user32.lookupFunction<
        Int32 Function(IntPtr, IntPtr, Int32, Int32, Int32, Int32, Uint32),
        int Function(int, int, int, int, int, int, int)
      >('SetWindowPos');
  }

  final DynamicLibrary _user32;
  late final int Function(Pointer<Utf16>, Pointer<Utf16>) _findWindow;
  late final int Function(int, int, Pointer<Utf16>, Pointer<Utf16>)
      _findWindowEx;
  late final int Function(int, Pointer<_NativeRect>) _getWindowRect;
  late final int Function(int) _isWindowVisible;
  late final int Function(int, int, int, int, int, int, int) _setWindowPos;

  int findPanel() {
    final title = _panelTitle.toNativeUtf16();
    try {
      return _findWindow(_nullUtf16, title);
    } finally {
      calloc.free(title);
    }
  }

  int isWindowVisible(int handle) => _isWindowVisible(handle);

  _RectSnapshot? windowRect(int handle) {
    final rect = calloc<_NativeRect>();
    try {
      if (_getWindowRect(handle, rect) == 0) {
        return null;
      }
      final value = rect.ref;
      return _RectSnapshot(value.left, value.top, value.right, value.bottom);
    } finally {
      calloc.free(rect);
    }
  }

  List<_RectSnapshot> taskbarRects() {
    final rects = <_RectSnapshot>[];
    final primaryClass = 'Shell_TrayWnd'.toNativeUtf16();
    final secondaryClass = 'Shell_SecondaryTrayWnd'.toNativeUtf16();
    try {
      _addVisibleRect(_findWindow(primaryClass, _nullUtf16), rects);
      var previous = 0;
      while (true) {
        final taskbar = _findWindowEx(
          0,
          previous,
          secondaryClass,
          _nullUtf16,
        );
        if (taskbar == 0) {
          break;
        }
        _addVisibleRect(taskbar, rects);
        previous = taskbar;
      }
    } finally {
      calloc.free(primaryClass);
      calloc.free(secondaryClass);
    }
    return rects;
  }

  void setTopmost(int handle) {
    const hwndTopmost = -1;
    const flags = 0x0001 | 0x0002 | 0x0010;
    _setWindowPos(handle, hwndTopmost, 0, 0, 0, 0, flags);
  }

  void _addVisibleRect(int handle, List<_RectSnapshot> rects) {
    if (handle == 0 || _isWindowVisible(handle) == 0) {
      return;
    }
    final rect = windowRect(handle);
    if (rect != null) {
      rects.add(rect);
    }
  }

  static final _nullUtf16 = Pointer<Utf16>.fromAddress(0);
}
