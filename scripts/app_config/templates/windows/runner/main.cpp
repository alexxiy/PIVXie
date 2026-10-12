#include <flutter/dart_project.h>
#include <flutter/flutter_view_controller.h>
#include <windows.h>

#include <string>

#include "app_links/app_links_plugin_c_api.h"
#include "flutter_window.h"
#include "utils.h"

namespace {

// The command line is a pivx: link (as the registered handler passes it,
// quoted).
bool IsPaymentLink(const wchar_t* command_line) {
  if (command_line == nullptr) return false;
  while (*command_line == L' ' || *command_line == L'"') command_line++;
  return _wcsnicmp(command_line, L"pivx:", 5) == 0;
}

// Open pivx: links with this app, unless another installed app (e.g. PIVX
// Core) already does. Per user, so no admin rights are needed.
void RegisterPaymentLinks() {
  wchar_t exe[MAX_PATH];
  if (GetModuleFileNameW(nullptr, exe, MAX_PATH) == 0) return;

  wchar_t current[MAX_PATH * 2];
  DWORD size = sizeof(current);
  if (RegGetValueW(HKEY_CLASSES_ROOT, L"pivx\\shell\\open\\command", nullptr,
                   RRF_RT_REG_SZ, nullptr, current, &size) == ERROR_SUCCESS) {
    std::wstring handler(current);
    if (!handler.empty() && handler[0] == L'"') {
      handler = handler.substr(1, handler.find(L'"', 1) - 1);
    } else {
      handler = handler.substr(0, handler.find(L' '));
    }
    if (_wcsicmp(handler.c_str(), exe) == 0) return;
    if (GetFileAttributesW(handler.c_str()) != INVALID_FILE_ATTRIBUTES) return;
  }

  const std::wstring command = L"\"" + std::wstring(exe) + L"\" \"%1\"";
  const std::wstring name = L"URL:PIVX payment";
  RegSetKeyValueW(HKEY_CURRENT_USER, L"Software\\Classes\\pivx", nullptr,
                  REG_SZ, name.c_str(),
                  static_cast<DWORD>((name.size() + 1) * sizeof(wchar_t)));
  RegSetKeyValueW(HKEY_CURRENT_USER, L"Software\\Classes\\pivx",
                  L"URL Protocol", REG_SZ, L"", sizeof(wchar_t));
  RegSetKeyValueW(HKEY_CURRENT_USER,
                  L"Software\\Classes\\pivx\\shell\\open\\command", nullptr,
                  REG_SZ, command.c_str(),
                  static_cast<DWORD>((command.size() + 1) * sizeof(wchar_t)));
}

}  // namespace

int APIENTRY wWinMain(_In_ HINSTANCE instance, _In_opt_ HINSTANCE prev,
                      _In_ wchar_t *command_line, _In_ int show_command) {
  // A pivx: link while the app runs: hand it to that window, then exit.
  if (IsPaymentLink(command_line) && SendAppLinkToInstance()) {
    return EXIT_SUCCESS;
  }
  RegisterPaymentLinks();

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

  FlutterWindow window(project);
  Win32Window::Point origin(10, 10);
  Win32Window::Size size(1280, 720);
  if (!window.CreateAndShow(L"PlaceHolderName", origin, size)) {
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
