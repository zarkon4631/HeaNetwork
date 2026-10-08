// Hand-written bindings for the handful of Win32 calls the app needs.
// Only loaded on Windows; everything here is synchronous and cheap.
import 'dart:ffi';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';

final _kernel32 = DynamicLibrary.open('kernel32.dll');
final _shell32 = DynamicLibrary.open('shell32.dll');
final _user32 = DynamicLibrary.open('user32.dll');
final _gdi32 = DynamicLibrary.open('gdi32.dll');
final _advapi32 = DynamicLibrary.open('advapi32.dll');
final _wininet = DynamicLibrary.open('wininet.dll');
final _version = DynamicLibrary.open('version.dll');

// ---- processes -----------------------------------------------------------

final _enumProcesses = _kernel32.lookupFunction<
    Int32 Function(Pointer<Uint32>, Uint32, Pointer<Uint32>),
    int Function(Pointer<Uint32>, int, Pointer<Uint32>)>('K32EnumProcesses');
final _openProcess = _kernel32.lookupFunction<
    IntPtr Function(Uint32, Int32, Uint32),
    int Function(int, int, int)>('OpenProcess');
final _closeHandle = _kernel32
    .lookupFunction<Int32 Function(IntPtr), int Function(int)>('CloseHandle');
final _queryImageName = _kernel32.lookupFunction<
    Int32 Function(IntPtr, Uint32, Pointer<Utf16>, Pointer<Uint32>),
    int Function(int, int, Pointer<Utf16>, Pointer<Uint32>)>(
    'QueryFullProcessImageNameW');

const _processQueryLimitedInformation = 0x1000;

/// Full executable paths of all running processes this user may query,
/// de-duplicated. Protected system processes are silently skipped.
List<String> runningExecutables() {
  return using((arena) {
    var capacity = 2048;
    late Pointer<Uint32> pids;
    late int count;
    final needed = arena<Uint32>();
    while (true) {
      pids = arena<Uint32>(capacity);
      if (_enumProcesses(pids, capacity * 4, needed) == 0) return <String>[];
      count = needed.value ~/ 4;
      if (count < capacity) break;
      capacity *= 2;
    }

    final seen = <String>{};
    final out = <String>[];
    final buf = arena<Uint16>(1024).cast<Utf16>();
    final size = arena<Uint32>();
    for (var i = 0; i < count; i++) {
      final pid = pids[i];
      if (pid == 0) continue;
      final h = _openProcess(_processQueryLimitedInformation, 0, pid);
      if (h == 0) continue;
      size.value = 1024;
      if (_queryImageName(h, 0, buf, size) != 0) {
        final path = buf.toDartString(length: size.value);
        if (seen.add(path.toLowerCase())) out.add(path);
      }
      _closeHandle(h);
    }
    return out;
  });
}

/// Executable path of process [pid], or null if it is gone or inaccessible.
String? processPath(int pid) {
  return using((arena) {
    final h = _openProcess(_processQueryLimitedInformation, 0, pid);
    if (h == 0) return null;
    try {
      final buf = arena<Uint16>(1024).cast<Utf16>();
      final size = arena<Uint32>()..value = 1024;
      if (_queryImageName(h, 0, buf, size) == 0) return null;
      return buf.toDartString(length: size.value);
    } finally {
      _closeHandle(h);
    }
  });
}

// ---- elevation -----------------------------------------------------------

final _isUserAnAdmin = _shell32
    .lookupFunction<Int32 Function(), int Function()>('IsUserAnAdmin');
final _shellExecute = _shell32.lookupFunction<
    IntPtr Function(IntPtr, Pointer<Utf16>, Pointer<Utf16>, Pointer<Utf16>,
        Pointer<Utf16>, Int32),
    int Function(int, Pointer<Utf16>, Pointer<Utf16>, Pointer<Utf16>,
        Pointer<Utf16>, int)>('ShellExecuteW');

bool isElevated() => _isUserAnAdmin() != 0;

/// Runs [file] through the shell with [verb] (`runas` asks for elevation,
/// `open` just launches). Returns false if the user declined or it failed.
bool shellExecute(String file, {String verb = 'open', String args = ''}) {
  return using((arena) {
    final r = _shellExecute(
      0,
      verb.toNativeUtf16(allocator: arena),
      file.toNativeUtf16(allocator: arena),
      args.toNativeUtf16(allocator: arena),
      nullptr,
      1, // SW_SHOWNORMAL
    );
    return r > 32;
  });
}

// ---- registry ------------------------------------------------------------

const hkeyCurrentUser = 0x80000001;
const _keyRead = 0x20019;
const _keyWrite = 0x20006;
const _regSz = 1;
const _regDword = 4;

final _regCreateKey = _advapi32.lookupFunction<
    Int32 Function(IntPtr, Pointer<Utf16>, Uint32, Pointer<Utf16>, Uint32,
        Uint32, Pointer<Void>, Pointer<IntPtr>, Pointer<Uint32>),
    int Function(int, Pointer<Utf16>, int, Pointer<Utf16>, int, int,
        Pointer<Void>, Pointer<IntPtr>, Pointer<Uint32>)>('RegCreateKeyExW');
final _regOpenKey = _advapi32.lookupFunction<
    Int32 Function(IntPtr, Pointer<Utf16>, Uint32, Uint32, Pointer<IntPtr>),
    int Function(int, Pointer<Utf16>, int, int, Pointer<IntPtr>)>('RegOpenKeyExW');
final _regSetValue = _advapi32.lookupFunction<
    Int32 Function(IntPtr, Pointer<Utf16>, Uint32, Uint32, Pointer<Uint8>, Uint32),
    int Function(int, Pointer<Utf16>, int, int, Pointer<Uint8>, int)>(
    'RegSetValueExW');
final _regQueryValue = _advapi32.lookupFunction<
    Int32 Function(IntPtr, Pointer<Utf16>, Pointer<Uint32>, Pointer<Uint32>,
        Pointer<Uint8>, Pointer<Uint32>),
    int Function(int, Pointer<Utf16>, Pointer<Uint32>, Pointer<Uint32>,
        Pointer<Uint8>, Pointer<Uint32>)>('RegQueryValueExW');
final _regDeleteValue = _advapi32.lookupFunction<
    Int32 Function(IntPtr, Pointer<Utf16>),
    int Function(int, Pointer<Utf16>)>('RegDeleteValueW');
final _regDeleteKey = _advapi32.lookupFunction<
    Int32 Function(IntPtr, Pointer<Utf16>),
    int Function(int, Pointer<Utf16>)>('RegDeleteKeyW');
final _regCloseKey = _advapi32
    .lookupFunction<Int32 Function(IntPtr), int Function(int)>('RegCloseKey');

/// A value under `HKEY_CURRENT_USER\[path]`. Strings and DWORDs only.
class RegistryValue {
  const RegistryValue(this.path, this.name);
  final String path;
  final String name;

  T? _withKey<T>(int access, bool create, T? Function(int key, Arena arena) body) {
    return using((arena) {
      final out = arena<IntPtr>();
      final p = path.toNativeUtf16(allocator: arena);
      final status = create
          ? _regCreateKey(hkeyCurrentUser, p, 0, nullptr, 0, access, nullptr, out, nullptr)
          : _regOpenKey(hkeyCurrentUser, p, 0, access, out);
      if (status != 0) return null;
      try {
        return body(out.value, arena);
      } finally {
        _regCloseKey(out.value);
      }
    });
  }

  /// The value as a String or int, or null if it does not exist.
  Object? read() => _withKey(_keyRead, false, (key, arena) {
        final n = name.toNativeUtf16(allocator: arena);
        final type = arena<Uint32>();
        final size = arena<Uint32>();
        if (_regQueryValue(key, n, nullptr, type, nullptr, size) != 0) return null;
        final data = arena<Uint8>(size.value + 2);
        if (_regQueryValue(key, n, nullptr, type, data, size) != 0) return null;
        if (type.value == _regDword) return data.cast<Uint32>().value;
        if (type.value == _regSz || type.value == 2) {
          final chars = size.value ~/ 2;
          final s = data.cast<Utf16>().toDartString(length: chars);
          final nul = s.indexOf('\u0000');
          return nul < 0 ? s : s.substring(0, nul);
        }
        return null;
      });

  String? readString() {
    final v = read();
    return v is String ? v : null;
  }

  int? readInt() {
    final v = read();
    return v is int ? v : null;
  }

  bool writeString(String value) =>
      _withKey(_keyWrite, true, (key, arena) {
        final data = value.toNativeUtf16(allocator: arena);
        return _regSetValue(key, name.toNativeUtf16(allocator: arena), 0,
                _regSz, data.cast(), (value.length + 1) * 2) ==
            0;
      }) ??
      false;

  bool writeInt(int value) =>
      _withKey(_keyWrite, true, (key, arena) {
        final data = arena<Uint32>()..value = value;
        return _regSetValue(key, name.toNativeUtf16(allocator: arena), 0,
                _regDword, data.cast(), 4) ==
            0;
      }) ??
      false;

  /// True when the value is gone afterwards (including "was never there").
  bool delete() =>
      _withKey(_keyWrite, false, (key, arena) {
        final r = _regDeleteValue(key, name.toNativeUtf16(allocator: arena));
        return r == 0 || r == 2; // ERROR_FILE_NOT_FOUND
      }) ??
      true;
}

/// Removes an empty key under HKCU. Used by tests to clean up.
bool deleteRegistryKey(String path) => using(
    (arena) => _regDeleteKey(hkeyCurrentUser, path.toNativeUtf16(allocator: arena)) == 0);

// ---- wininet -------------------------------------------------------------

final _internetSetOption = _wininet.lookupFunction<
    Int32 Function(IntPtr, Uint32, Pointer<Void>, Uint32),
    int Function(int, int, Pointer<Void>, int)>('InternetSetOptionW');

/// Tells running programs to re-read the system proxy settings.
void notifyProxySettingsChanged() {
  _internetSetOption(0, 39, nullptr, 0); // INTERNET_OPTION_SETTINGS_CHANGED
  _internetSetOption(0, 37, nullptr, 0); // INTERNET_OPTION_REFRESH
}

// ---- file description ----------------------------------------------------

final _verInfoSize = _version.lookupFunction<
    Uint32 Function(Pointer<Utf16>, Pointer<Uint32>),
    int Function(Pointer<Utf16>, Pointer<Uint32>)>('GetFileVersionInfoSizeW');
final _verInfo = _version.lookupFunction<
    Int32 Function(Pointer<Utf16>, Uint32, Uint32, Pointer<Void>),
    int Function(Pointer<Utf16>, int, int, Pointer<Void>)>('GetFileVersionInfoW');
final _verQuery = _version.lookupFunction<
    Int32 Function(Pointer<Void>, Pointer<Utf16>, Pointer<Pointer<Void>>,
        Pointer<Uint32>),
    int Function(Pointer<Void>, Pointer<Utf16>, Pointer<Pointer<Void>>,
        Pointer<Uint32>)>('VerQueryValueW');

/// The "File description" of an executable (e.g. `Google Chrome`), or null.
String? fileDescription(String path) {
  return using((arena) {
    final p = path.toNativeUtf16(allocator: arena);
    final size = _verInfoSize(p, nullptr);
    if (size == 0) return null;
    final block = arena<Uint8>(size).cast<Void>();
    if (_verInfo(p, 0, size, block) == 0) return null;

    final value = arena<Pointer<Void>>();
    final len = arena<Uint32>();
    if (_verQuery(block, r'\VarFileInfo\Translation'.toNativeUtf16(allocator: arena),
                value, len) ==
            0 ||
        len.value < 4) {
      return null;
    }
    final lang = value.value.cast<Uint16>()[0];
    final codePage = value.value.cast<Uint16>()[1];
    String hex(int v) => v.toRadixString(16).padLeft(4, '0');
    final key = '\\StringFileInfo\\${hex(lang)}${hex(codePage)}\\FileDescription';
    if (_verQuery(block, key.toNativeUtf16(allocator: arena), value, len) == 0 ||
        len.value == 0) {
      return null;
    }
    final s = value.value.cast<Utf16>().toDartString(length: len.value);
    final nul = s.indexOf('\u0000');
    final text = (nul < 0 ? s : s.substring(0, nul)).trim();
    return text.isEmpty ? null : text;
  });
}

// ---- icons ---------------------------------------------------------------

final _shGetFileInfo = _shell32.lookupFunction<
    IntPtr Function(Pointer<Utf16>, Uint32, Pointer<Void>, Uint32, Uint32),
    int Function(Pointer<Utf16>, int, Pointer<Void>, int, int)>('SHGetFileInfoW');
final _getIconInfo = _user32.lookupFunction<
    Int32 Function(IntPtr, Pointer<Void>),
    int Function(int, Pointer<Void>)>('GetIconInfo');
final _destroyIcon = _user32
    .lookupFunction<Int32 Function(IntPtr), int Function(int)>('DestroyIcon');
final _getDC =
    _user32.lookupFunction<IntPtr Function(IntPtr), int Function(int)>('GetDC');
final _releaseDC = _user32.lookupFunction<Int32 Function(IntPtr, IntPtr),
    int Function(int, int)>('ReleaseDC');
final _getObject = _gdi32.lookupFunction<
    Int32 Function(IntPtr, Int32, Pointer<Void>),
    int Function(int, int, Pointer<Void>)>('GetObjectW');
final _getDIBits = _gdi32.lookupFunction<
    Int32 Function(IntPtr, IntPtr, Uint32, Uint32, Pointer<Void>, Pointer<Void>,
        Uint32),
    int Function(int, int, int, int, Pointer<Void>, Pointer<Void>, int)>(
    'GetDIBits');
final _deleteObject = _gdi32
    .lookupFunction<Int32 Function(IntPtr), int Function(int)>('DeleteObject');

class IconPixels {
  IconPixels(this.width, this.height, this.bgra);
  final int width;
  final int height;

  /// Top-down, premultiplied BGRA, ready for `decodeImageFromPixels`.
  final Uint8List bgra;
}

/// The 32x32 shell icon of [path], or null when it has none.
IconPixels? fileIcon(String path) {
  return using((arena) {
    const shFileInfoSize = 696; // sizeof(SHFILEINFOW) on x64/arm64
    final info = arena<Uint8>(shFileInfoSize);
    final ok = _shGetFileInfo(path.toNativeUtf16(allocator: arena), 0,
        info.cast(), shFileInfoSize, 0x100 /* SHGFI_ICON | SHGFI_LARGEICON */);
    final hIcon = info.cast<IntPtr>().value;
    if (ok == 0 || hIcon == 0) return null;

    // ICONINFO: fIcon, xHotspot, yHotspot, pad, hbmMask@16, hbmColor@24.
    final iconInfo = arena<Uint8>(32);
    if (_getIconInfo(hIcon, iconInfo.cast()) == 0) {
      _destroyIcon(hIcon);
      return null;
    }
    final hMask = (iconInfo + 16).cast<IntPtr>().value;
    final hColor = (iconInfo + 24).cast<IntPtr>().value;

    IconPixels? result;
    if (hColor != 0) {
      // BITMAP: bmType, bmWidth@4, bmHeight@8, ...
      final bm = arena<Uint8>(32);
      if (_getObject(hColor, 32, bm.cast()) != 0) {
        final width = (bm + 4).cast<Int32>().value;
        final height = (bm + 8).cast<Int32>().value;
        if (width > 0 && height > 0 && width <= 256 && height <= 256) {
          // BITMAPINFOHEADER, asking for 32-bit top-down RGB.
          final bmi = arena<Uint8>(64);
          final h = bmi.cast<Int32>();
          h[0] = 40;
          h[1] = width;
          h[2] = -height;
          (bmi + 12).cast<Uint16>().value = 1;
          (bmi + 14).cast<Uint16>().value = 32;
          final bytes = width * height * 4;
          final pixels = arena<Uint8>(bytes);
          final dc = _getDC(0);
          final lines =
              _getDIBits(dc, hColor, 0, height, pixels.cast(), bmi.cast(), 0);
          _releaseDC(0, dc);
          if (lines == height) {
            final data = Uint8List.fromList(pixels.asTypedList(bytes));
            _premultiply(data);
            result = IconPixels(width, height, data);
          }
        }
      }
    }
    if (hColor != 0) _deleteObject(hColor);
    if (hMask != 0) _deleteObject(hMask);
    _destroyIcon(hIcon);
    return result;
  });
}

void _premultiply(Uint8List bgra) {
  var anyAlpha = false;
  for (var i = 3; i < bgra.length; i += 4) {
    if (bgra[i] != 0) {
      anyAlpha = true;
      break;
    }
  }
  for (var i = 0; i < bgra.length; i += 4) {
    if (!anyAlpha) {
      // Icons without an alpha channel report zero alpha everywhere.
      bgra[i + 3] = 255;
      continue;
    }
    final a = bgra[i + 3];
    if (a == 255) continue;
    bgra[i] = bgra[i] * a ~/ 255;
    bgra[i + 1] = bgra[i + 1] * a ~/ 255;
    bgra[i + 2] = bgra[i + 2] * a ~/ 255;
  }
}
