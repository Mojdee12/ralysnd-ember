#include <flutter/dart_project.h>
#include <flutter/flutter_view_controller.h>
#include <flutter_windows.h>
#include <windows.h>

#include <functional>
#include <string>
#include <vector>

#include "flutter_window.h"
#include "utils.h"

namespace {

// The copy of the app this process is: one per data folder, so a second
// launch shows the running window instead of opening another.
std::wstring InstanceKey(const std::vector<std::string>& args) {
  std::string data_dir;
  for (const auto& arg : args) {
    if (arg.rfind("--data-dir=", 0) == 0) {
      data_dir = arg.substr(11);
    }
  }
  return std::to_wstring(std::hash<std::string>{}(data_dir) & 0x7fffffff);
}

bool HasArgument(const std::vector<std::string>& args, const char* name) {
  for (const auto& arg : args) {
    if (arg == name) {
      return true;
    }
  }
  return false;
}

// The window's origin, in logical pixels, that centers [size] in the
// primary monitor's work area.
Win32Window::Point CenteredOrigin(const Win32Window::Size& size) {
  RECT work;
  SystemParametersInfoW(SPI_GETWORKAREA, 0, &work, 0);
  HMONITOR monitor = MonitorFromPoint(POINT{0, 0}, MONITOR_DEFAULTTOPRIMARY);
  double scale = FlutterDesktopGetDpiForMonitor(monitor) / 96.0;
  double width = (work.right - work.left) / scale;
  double height = (work.bottom - work.top) / scale;
  double x = work.left / scale + (width - size.width) / 2;
  double y = work.top / scale + (height - size.height) / 2;
  return Win32Window::Point(static_cast<unsigned int>(x > 0 ? x : 0),
                            static_cast<unsigned int>(y > 0 ? y : 0));
}

}  // namespace

int APIENTRY wWinMain(_In_ HINSTANCE instance, _In_opt_ HINSTANCE prev,
                      _In_ wchar_t *command_line, _In_ int show_command) {
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

  const std::wstring key = InstanceKey(command_line_arguments);
  HANDLE instance_mutex =
      ::CreateMutexW(nullptr, TRUE, (L"Local\\VPNClient-" + key).c_str());
  if (::GetLastError() == ERROR_ALREADY_EXISTS) {
    // A protocol activation (ovpn:// / openvpn://) hands its
    // link to the running copy: leave it in the app data
    // folder's pending-link.txt, which the shell drains when
    // the window comes forward (desktop/pending_link.dart).
    for (const auto& arg : command_line_arguments) {
      std::string lower = arg;
      for (auto& c : lower) c = static_cast<char>(::tolower(c));
      if (lower.rfind("ovpn://", 0) == 0 ||
          lower.rfind("openvpn://", 0) == 0) {
        wchar_t exe_path[MAX_PATH] = {};
        ::GetModuleFileNameW(nullptr, exe_path, MAX_PATH);
        std::wstring dir(exe_path);
        const auto slash = dir.find_last_of(L"\\/");
        if (slash != std::wstring::npos) {
          dir.resize(slash);
          const std::wstring file =
              dir + L"\\user-data\\pending-link.txt";
          HANDLE h = ::CreateFileW(file.c_str(), GENERIC_WRITE, 0, nullptr,
                                   CREATE_ALWAYS, FILE_ATTRIBUTE_NORMAL,
                                   nullptr);
          if (h != INVALID_HANDLE_VALUE) {
            DWORD written = 0;
            ::WriteFile(h, arg.data(),
                        static_cast<DWORD>(arg.size()), &written, nullptr);
            ::CloseHandle(h);
          }
        }
        break;
      }
    }
    // Ask the running copy to show its window, and let it take the focus.
    ::AllowSetForegroundWindow(ASFW_ANY);
    ::PostMessageW(HWND_BROADCAST, ::RegisterWindowMessageW(L"VPNClient.Activate"),
                   static_cast<WPARAM>(std::stoul(key)), 0);
    if (instance_mutex) {
      ::CloseHandle(instance_mutex);
    }
    ::CoUninitialize();
    return EXIT_SUCCESS;
  }
  // Started by Windows at sign-in, or by an update of a copy that was in
  // the tray: stay in the tray.
  const bool start_hidden = HasArgument(command_line_arguments, "--autostart") ||
                            HasArgument(command_line_arguments, "--hidden");

  project.set_dart_entrypoint_arguments(std::move(command_line_arguments));

  FlutterWindow window(project, static_cast<WPARAM>(std::stoul(key)), start_hidden);
  Win32Window::Size size(1200, 780);
  Win32Window::Point origin = CenteredOrigin(size);
  if (!window.Create(L"Ralysnd Ember", origin, size)) {
    return EXIT_FAILURE;
  }
  window.SetQuitOnClose(true);

  ::MSG msg;
  while (::GetMessage(&msg, nullptr, 0, 0)) {
    ::TranslateMessage(&msg);
    ::DispatchMessage(&msg);
  }

  if (instance_mutex) {
    ::CloseHandle(instance_mutex);
  }
  ::CoUninitialize();
  return EXIT_SUCCESS;
}
