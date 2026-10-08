import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:provider/provider.dart';

import 'state/app_state.dart';
import 'ui/shell.dart';
import 'ui/theme.dart';

/// Lets code outside the widget tree (the tray menu) raise dialogs.
final appNavigatorKey = GlobalKey<NavigatorState>();

class HeaApp extends StatelessWidget {
  const HeaApp({super.key, required this.state, this.home});

  final AppState state;

  /// Replaces the shell; used by tests to show a single page.
  final Widget? home;

  @override
  Widget build(BuildContext context) {
    return ChangeNotifierProvider<AppState>.value(
      value: state,
      child: Selector<AppState, (String, String)>(
        selector: (_, s) => (s.settings.locale, s.settings.themeMode),
        builder: (context, prefs, _) {
          final (locale, theme) = prefs;
          return MaterialApp(
            title: 'HeaNetwork',
            navigatorKey: appNavigatorKey,
            debugShowCheckedModeBanner: false,
            theme: buildTheme(Brightness.light),
            darkTheme: buildTheme(Brightness.dark),
            themeMode: switch (theme) {
              'light' => ThemeMode.light,
              'dark' => ThemeMode.dark,
              _ => ThemeMode.system,
            },
            locale: locale == 'system' ? null : Locale(locale),
            supportedLocales: const [Locale('ru'), Locale('en')],
            localizationsDelegates: GlobalMaterialLocalizations.delegates,
            // Anything that is not Russian gets English.
            localeResolutionCallback: (device, _) =>
                device?.languageCode == 'ru' ? const Locale('ru') : const Locale('en'),
            home: home ?? const Shell(),
          );
        },
      ),
    );
  }
}
