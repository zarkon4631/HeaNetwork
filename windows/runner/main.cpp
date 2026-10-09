#include <flutter/dart_project.h>
#include <flutter/flutter_view_controller.h>
#include <windows.h>

#include <sddl.h>

#include <cwchar>

#include "flutter_window.h"
#include "utils.h"

namespace {

constexpr wchar_t kWindowTitle[] = L"HeaNetwork";
constexpr wchar_t kWindowClass[] = L"FLUTTER_RUNNER_WIN32_WINDOW";
constexpr wchar_t kInstanceMutex[] = L"HeaNetwork.SingleInstance";
constexpr wchar_t kShowEvent[] = L"HeaNetwork.ShowWindow";

// Access rights for the two objects copies of the app find each other by.
// The running copy may be elevated (VPN mode) while the one just launched
// is not. With default security that launch could neither see the mutex
// nor reach the window, and a second copy would start next to the first.
// The objects carry nothing: one says "running", the other "show yourself",
// so everyone may use them.
class SharedAccess {
 public:
  SharedAccess() {
    // D: everyone, full access. S: usable from medium integrity.
    if (::ConvertStringSecurityDescriptorToSecurityDescriptorW(
            L"D:(A;;GA;;;WD)S:(ML;;NW;;;ME)", SDDL_REVISION_1, &descriptor_,
            nullptr)) {
      attributes_.nLength = sizeof(attributes_);
      attributes_.lpSecurityDescriptor = descriptor_;
      attributes_.bInheritHandle = FALSE;
    }
  }
  ~SharedAccess() {
    if (descriptor_ != nullptr) {
      ::LocalFree(descriptor_);
    }
  }
  SharedAccess(const SharedAccess&) = delete;
  SharedAccess& operator=(const SharedAccess&) = delete;

  SECURITY_ATTRIBUTES* get() {
    return descriptor_ != nullptr ? &attributes_ : nullptr;
  }

 private:
  SECURITY_ATTRIBUTES attributes_{};
  PSECURITY_DESCRIPTOR descriptor_ = nullptr;
};

// Shows a window that may be minimised or hidden to the tray.
void ShowAppWindow(HWND hwnd) {
  ::ShowWindow(hwnd, ::IsIconic(hwnd) ? SW_RESTORE : SW_SHOW);
  ::SetForegroundWindow(hwnd);
}

// Brings the window of the already running copy to the front.
void ActivateRunningInstance() {
  // This launch is what the user just did, so it may hand the foreground on.
  ::AllowSetForegroundWindow(ASFW_ANY);
  // The event reaches a copy with more rights than this one; Windows does
  // not let a normal process operate an administrator's window directly.
  HANDLE show = ::OpenEventW(EVENT_MODIFY_STATE, FALSE, kShowEvent);
  if (show != nullptr) {
    ::SetEvent(show);
    ::CloseHandle(show);
  }
  HWND hwnd = ::FindWindowW(kWindowClass, kWindowTitle);
  if (hwnd != nullptr) {
    ShowAppWindow(hwnd);
  }
}

// Called on a thread-pool thread whenever another launch signals the event.
void CALLBACK OnShowRequested(void* window, BOOLEAN) {
  ShowAppWindow(static_cast<HWND>(window));
}

}  // namespace

int APIENTRY wWinMain(_In_ HINSTANCE instance, _In_opt_ HINSTANCE prev,
                      _In_ wchar_t *command_line, _In_ int show_command) {
  // One copy at a time: two would fight over the system proxy and the core.
  // `--elevated` is passed when the app restarts itself as administrator;
  // the unelevated copy is still exiting then, so it must not block us.
  SharedAccess shared;
  HANDLE mutex = ::CreateMutexW(shared.get(), TRUE, kInstanceMutex);
  const DWORD mutex_error = ::GetLastError();
  // A mutex this launch is denied belongs to an elevated copy of a version
  // that did not share it yet: a running copy all the same.
  const bool already_running =
      mutex_error == ERROR_ALREADY_EXISTS ||
      (mutex == nullptr && mutex_error == ERROR_ACCESS_DENIED);
  const bool elevated_relaunch = std::wcsstr(command_line, L"--elevated") != nullptr;
  if (already_running && !elevated_relaunch) {
    ActivateRunningInstance();
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

  FlutterWindow window(project);
  Win32Window::Point origin(10, 10);
  Win32Window::Size size(980, 720);
  if (!window.Create(kWindowTitle, origin, size)) {
    return EXIT_FAILURE;
  }
  window.SetQuitOnClose(true);

  // Later launches ask this copy to show its window through this event.
  HANDLE show_event = ::CreateEventW(shared.get(), FALSE, FALSE, kShowEvent);
  HANDLE show_wait = nullptr;
  if (show_event != nullptr) {
    ::RegisterWaitForSingleObject(&show_wait, show_event, OnShowRequested,
                                  window.GetHandle(), INFINITE,
                                  WT_EXECUTEDEFAULT);
  }

  ::MSG msg;
  while (::GetMessage(&msg, nullptr, 0, 0)) {
    ::TranslateMessage(&msg);
    ::DispatchMessage(&msg);
  }

  if (show_wait != nullptr) {
    ::UnregisterWait(show_wait);
  }
  ::CoUninitialize();
  return EXIT_SUCCESS;
}
