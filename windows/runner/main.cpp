#include <flutter/dart_project.h>
#include <flutter/flutter_view_controller.h>
#include <windows.h>

#include <cmath>

#include <app_links/app_links_plugin_c_api.h>
#include <window_manager/window_manager_plugin.h>

#include "flutter_window.h"
#include "utils.h"

namespace {

Win32Window::Point CodexPanelOrigin() {
  const POINT primary_point = {0, 0};
  const HMONITOR monitor =
      MonitorFromPoint(primary_point, MONITOR_DEFAULTTOPRIMARY);
  MONITORINFO monitor_info{};
  monitor_info.cbSize = sizeof(MONITORINFO);
  if (monitor == nullptr || !GetMonitorInfo(monitor, &monitor_info)) {
    return Win32Window::Point(10, 10);
  }

  const UINT dpi = GetDpiForSystem();
  const double scale = dpi == 0 ? 1.0 : static_cast<double>(dpi) / 96.0;
  const unsigned int width = 360;
  const unsigned int height = 36;
  const unsigned int inset = 8;
  const int left =
      static_cast<int>(std::lround(monitor_info.rcMonitor.left / scale));
  const int right =
      static_cast<int>(std::lround(monitor_info.rcMonitor.right / scale));
  const int bottom =
      static_cast<int>(std::lround(monitor_info.rcMonitor.bottom / scale));
  const unsigned int x = static_cast<unsigned int>(
      left + ((right - left - static_cast<int>(width)) / 2));
  const unsigned int y = static_cast<unsigned int>(
      bottom - static_cast<int>(height + inset));
  return Win32Window::Point(x, y);
}

}  // namespace

int APIENTRY wWinMain(_In_ HINSTANCE instance, _In_opt_ HINSTANCE prev,
                      _In_ wchar_t *command_line, _In_ int show_command) {
  // Attach to console when present (e.g., 'flutter run') or create a
  // new console when running with a debugger.
  if (!::AttachConsole(ATTACH_PARENT_PROCESS) && ::IsDebuggerPresent()) {
    CreateAndAttachConsole();
  }

  std::vector<std::string> command_line_arguments =
      GetCommandLineArguments();
  bool is_codex_panel = false;
  for (const auto &argument : command_line_arguments) {
    if (argument == "--codex-panel" || argument == "--codex-panel-preview") {
      is_codex_panel = true;
      break;
    }
  }

  if (!is_codex_panel) {
    if (HWND running = WindowManagerFindRunningWindow()) {
      SendAppLink(running);
      WindowManagerActivateWindow(running);
      return EXIT_SUCCESS;
    }
  }

  // Initialize COM, so that it is available for use in the library and/or
  // plugins.
  ::CoInitializeEx(nullptr, COINIT_APARTMENTTHREADED);

  flutter::DartProject project(L"data");

  project.set_dart_entrypoint_arguments(std::move(command_line_arguments));

  FlutterWindow window(project);
  Win32Window::Point origin(10, 10);
  Win32Window::Size size = is_codex_panel
                               ? Win32Window::Size(360, 36)
                               : Win32Window::Size(1280, 720);
  if (is_codex_panel) {
    origin = CodexPanelOrigin();
  }
  if (!window.Create(is_codex_panel ? L"FlClash Codex Panel" : L"FlClash",
                    origin, size, is_codex_panel)) {
    return EXIT_FAILURE;
  }
  window.SetQuitOnClose(true);
  if (is_codex_panel) {
    window.Show();
  }

  ::MSG msg;
  while (::GetMessage(&msg, nullptr, 0, 0)) {
    ::TranslateMessage(&msg);
    ::DispatchMessage(&msg);
  }

  ::CoUninitialize();
  return EXIT_SUCCESS;
}
