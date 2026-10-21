#include <flutter/dart_project.h>
#include <flutter/flutter_view_controller.h>
#include <windows.h>

#include "app_links/app_links_plugin_c_api.h"
#include "flutter_window.h"
#include "utils.h"

int APIENTRY wWinMain(_In_ HINSTANCE instance, _In_opt_ HINSTANCE prev,
                      _In_ wchar_t *command_line, _In_ int show_command) {
  // One PocketTerm per user: a second start (a pocketterm:// link, the Start
  // menu, login) hands its link to the running one and brings its window up.
  if (SendAppLinkToInstance()) {
    return EXIT_SUCCESS;
  }
  // Held until the process exits. Catches a second start before the first one
  // has its window.
  HANDLE mutex = ::CreateMutexW(nullptr, TRUE, L"PocketTermSingleInstance");
  if (mutex != nullptr && ::GetLastError() == ERROR_ALREADY_EXISTS) {
    if (HWND w = ::FindWindowW(L"FLUTTER_RUNNER_WIN32_WINDOW", L"PocketTerm")) {
      ::ShowWindow(w, SW_SHOW);
      ::SetForegroundWindow(w);
    }
    return EXIT_SUCCESS;
  }

  // Attach to console when present (e.g., 'flutter run') or create a
  // new console when running with a debugger.
  if (!::AttachConsole(ATTACH_PARENT_PROCESS) && ::IsDebuggerPresent()) {
    CreateAndAttachConsole();
  }

  // Initialize COM, so that it is available for use in the library and/or
  // plugins.
  ::CoInitializeEx(nullptr, COINIT_APARTMENTTHREADED);

  flutter::DartProject project(L"data");

  std::vector<std::string> command_line_arguments =
      GetCommandLineArguments();

  project.set_dart_entrypoint_arguments(std::move(command_line_arguments));

  // Created hidden: Dart shows it (lib/windows_host.dart), unless the app was
  // started with --hidden at login.
  FlutterWindow window(project);
  Win32Window::Point origin(10, 10);
  // About 760 x 600 inside the frame: Settings' two columns of cards fit.
  Win32Window::Size size(776, 640);
  if (!window.Create(L"PocketTerm", origin, size)) {
    return EXIT_FAILURE;
  }
  window.SetQuitOnClose(true);

  ::MSG msg;
  while (::GetMessage(&msg, nullptr, 0, 0)) {
    ::TranslateMessage(&msg);
    ::DispatchMessage(&msg);
  }

  ::CoUninitialize();
  return EXIT_SUCCESS;
}
