import '../../core/models/settings.dart';
import 'system_proxy.dart' show Autostart;

/// Marks the copy of the app that was restarted as administrator. The copy
/// it replaces is still exiting at that moment, so the single-instance
/// guard lets a process with this flag through.
const elevatedFlag = '--elevated';

/// Asks the app to connect as soon as it is up.
const connectFlag = '--connect';

/// Whether a launch should hand over to an elevated copy straight away.
///
/// VPN mode cannot work without administrator rights, so a start in that
/// mode asks for them up front rather than at the first connect: the user
/// chose the mode, and being asked again on every launch is the price of
/// Windows not letting an app keep the rights. A start with Windows only
/// asks when it is also meant to connect; a prompt at every login just to
/// sit in the tray would be for nothing.
bool shouldElevateOnLaunch({
  required AppSettings settings,
  required bool elevated,
  required List<String> args,
}) {
  if (elevated || settings.mode != ConnectionMode.tun) return false;
  // Never ask twice in a row should the rights somehow not have arrived.
  if (args.contains(elevatedFlag)) return false;
  if (args.contains(Autostart.flag)) return settings.autoConnect;
  return true;
}

/// The command line for the elevated copy: what this one was started with,
/// plus the marker, plus [connect] when it should connect right away.
String elevatedArguments(List<String> args, {bool connect = false}) => [
      ...args.where((a) => a != elevatedFlag),
      elevatedFlag,
      if (connect && !args.contains(connectFlag)) connectFlag,
    ].join(' ');
