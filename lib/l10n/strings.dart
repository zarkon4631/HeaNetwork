import 'dart:ui' show PlatformDispatcher;

import 'package:flutter/widgets.dart';

/// UI strings in Russian and English, side by side so a missing
/// translation cannot compile.
class S {
  const S._(this._ru);
  final bool _ru;

  static const ru = S._(true);
  static const en = S._(false);

  static S of(BuildContext context) =>
      Localizations.localeOf(context).languageCode == 'ru' ? ru : en;

  /// The strings for the language chosen in the settings (`system`, `ru`,
  /// `en`), for what has no [BuildContext] to ask: the tray menu, the
  /// Android widget.
  static S forSetting(String locale) {
    final code =
        locale == 'system' ? PlatformDispatcher.instance.locale.languageCode : locale;
    return code == 'ru' ? ru : en;
  }

  String _t(String r, String e) => _ru ? r : e;

  // ---- navigation
  String get navHome => _t('Главная', 'Home');
  String get navRouting => _t('Маршруты', 'Routing');
  String get navSsh => _t('SSH', 'SSH');
  String get navSettings => _t('Настройки', 'Settings');

  // ---- common
  String get cancel => _t('Отмена', 'Cancel');
  String get save => _t('Сохранить', 'Save');
  String get add => _t('Добавить', 'Add');
  String get delete => _t('Удалить', 'Delete');
  String get rename => _t('Переименовать', 'Rename');
  String get close => _t('Закрыть', 'Close');
  String get copy => _t('Копировать', 'Copy');
  String get copied => _t('Скопировано', 'Copied');
  String get search => _t('Поиск', 'Search');
  String get name => _t('Название', 'Name');
  String get ok => _t('Понятно', 'OK');
  String get refresh => _t('Обновить', 'Refresh');

  // ---- home
  String get statusOff => _t('Отключено', 'Disconnected');
  String get statusConnecting => _t('Подключение…', 'Connecting…');
  String get statusOn => _t('Подключено', 'Connected');
  String get statusStopping => _t('Отключение…', 'Disconnecting…');
  String get tapToConnect => _t('Нажмите, чтобы подключиться', 'Tap to connect');
  String get tapToDisconnect => _t('Нажмите, чтобы отключиться', 'Tap to disconnect');
  String get noServer => _t('Сервер не выбран', 'No server selected');
  String get noServerHint => _t(
      'Добавьте сервер по ссылке, QR-коду или подписке',
      'Add a server from a link, a QR code or a subscription');
  String get addServer => _t('Добавить сервер', 'Add server');
  String get mode => _t('Режим', 'Mode');
  String get modeProxy => _t('Системный прокси', 'System proxy');
  String get modeTun => _t('VPN (весь трафик)', 'VPN (all traffic)');
  String get modeProxyHint => _t(
      'Только программы, которые используют системный прокси: браузеры и большинство приложений. Игры и консольные программы (Claude Code, git, npm) идут мимо VPN — для них включите режим VPN. Права администратора не нужны.',
      'Only programs that honour the system proxy: browsers and most apps. Games and command-line tools (Claude Code, git, npm) bypass the VPN — switch to VPN mode for those. No administrator rights needed.');
  String get modeTunHint => _t(
      'Весь трафик компьютера, включая игры и программы без поддержки прокси. Нужны права администратора.',
      'All traffic of this computer, including games and programs without proxy support. Needs administrator rights.');
  String get sessionTraffic => _t('За сеанс', 'This session');
  String get routingSummaryAll => _t('Весь трафик через VPN', 'All traffic through VPN');
  String get routingSummarySelected =>
      _t('Через VPN только выбранное', 'Only selected traffic through VPN');
  String routingExceptions(int n) => _t(
      '$n ${_plural(n, 'исключение', 'исключения', 'исключений')}',
      '$n ${n == 1 ? 'exception' : 'exceptions'}');
  String get errorTitle => _t('Не удалось подключиться', 'Could not connect');
  String get stackSwitched => _t(
      'Сетевой стек VPN переключён на gVisor', 'The VPN network stack was switched to gVisor');
  String get stackSwitchedHint => _t(
      'Через обычный стек туннель не принимал соединения: так бывает, когда файрвол или антивирус блокирует входящие подключения. Настройка сохранена; вернуть её можно в «Настройки → Подключение».',
      'The tunnel took no connections on the usual stack, which happens when a firewall or an antivirus blocks incoming connections. The setting is saved; it can be changed back under Settings → Connection.');
  String get routingSkipped => _t(
      'Подключено без правил маршрутизации', 'Connected without the routing rules');
  String get routingSkippedHint => _t(
      'Ядро не приняло правила сайтов или маршрутизацию из панели, поэтому подключение установлено без них. Проверьте правила на странице «Маршруты» или сообщите администратору панели.',
      'The core would not take the site rules or the panel’s routing, so the connection was made without them. Check the rules on the Routing page or tell the panel’s administrator.');
  String get needAdminTitle => _t('Нужны права администратора', 'Administrator rights needed');
  String get needAdminBody => _t(
      'Режим VPN создаёт виртуальный сетевой адаптер, для этого Windows требует права администратора. Перезапустить HeaNetwork с повышенными правами?',
      'VPN mode creates a virtual network adapter, which Windows only allows for administrators. Restart HeaNetwork with elevated rights?');
  String get restartAsAdmin => _t('Перезапустить', 'Restart');
  String get useProxyInstead => _t('Использовать системный прокси', 'Use system proxy instead');
  String get pendingRestart => _t(
      'Изменения вступят в силу после переподключения',
      'Changes take effect after reconnecting');
  String get reconnect => _t('Переподключить', 'Reconnect');
  String get measure => _t('Проверить', 'Test');

  // ---- servers
  String get serversEmptyTitle => _t('Пока нет серверов', 'No servers yet');
  String get serversEmptyBody => _t(
      'Скопируйте ссылку из панели 3x-ui и нажмите «Вставить из буфера», либо добавьте подписку.',
      'Copy a link from your 3x-ui panel and press “Paste from clipboard”, or add a subscription.');
  String get pasteFromClipboard => _t('Вставить из буфера', 'Paste from clipboard');
  String get scanQr => _t('Сканировать QR-код', 'Scan QR code');
  String get importFile => _t('Импорт из файла', 'Import from file');
  String get importFileHint => _t(
      'Конфигурация WireGuard / AmneziaWG (.conf), sing-box (.json) или список ссылок',
      'WireGuard / AmneziaWG (.conf), sing-box (.json) or a list of links');
  String get addSubscription => _t('Добавить подписку', 'Add subscription');
  String get subscriptionUrl => _t('Ссылка на подписку', 'Subscription URL');
  String get addManually => _t('Прокси вручную (SOCKS / HTTP)', 'Manual proxy (SOCKS / HTTP)');
  String get myServers => _t('Мои серверы', 'My servers');
  String get clipboardEmpty => _t('Буфер обмена пуст', 'The clipboard is empty');
  String imported(int n) => _t(
      'Добавлено: $n ${_plural(n, 'сервер', 'сервера', 'серверов')}',
      'Added $n ${n == 1 ? 'server' : 'servers'}');
  String get nothingImported =>
      _t('Не удалось распознать ни одного сервера', 'No server could be recognised');
  String skipped(int n) => _t('Пропущено: $n', 'Skipped: $n');

  /// What a server needs that the core does not have: `protocol:masque`
  /// reads "протокол MASQUE". Anything else is shown as it is.
  String unsupportedWhat(String reason) {
    final sep = reason.indexOf(':');
    if (sep <= 0) return reason;
    final name = reason.substring(sep + 1).toUpperCase();
    return switch (reason.substring(0, sep)) {
      'protocol' => _t('протокол $name', 'the $name protocol'),
      'transport' => _t('транспорт $name', 'the $name transport'),
      _ => reason,
    };
  }

  /// Servers that were left out of the list, by name and reason.
  String unsupportedServers(List<(String name, String reason)> servers) {
    final shown = servers.take(3).map((e) {
      final what = unsupportedWhat(e.$2);
      return e.$1.isEmpty ? what : '${e.$1} ($what)';
    }).join(', ');
    final more = servers.length - 3;
    final tail = more > 0 ? _t(' и ещё $more', ' and $more more') : '';
    return _t('Не показаны: $shown$tail. Ядро приложения с ними не работает.',
        'Not shown: $shown$tail. The app\'s core cannot connect to them.');
  }

  String onlyUnsupported(String what) => _t(
      'В подписке только серверы, с которыми ядро приложения не работает: $what',
      'The subscription only has servers the app\'s core cannot connect to: $what');
  String get share => _t('Поделиться', 'Share');
  String get shareHint => _t(
      'Отсканируйте код в HeaNetwork на телефоне или скопируйте ссылку',
      'Scan the code with HeaNetwork on your phone or copy the link');
  String get editJson => _t('Изменить JSON', 'Edit JSON');
  String get jsonHint => _t(
      'Исходящее подключение в формате sing-box. Для опытных пользователей.',
      'The outbound in sing-box format. For advanced users.');
  String get invalidJson => _t('Некорректный JSON', 'Invalid JSON');
  String get deleteServerQ => _t('Удалить сервер?', 'Delete this server?');
  String get deleteSubscriptionQ =>
      _t('Удалить подписку и её серверы?', 'Delete the subscription and its servers?');
  String updatedAt(String when) => _t('Обновлено $when', 'Updated $when');
  String get never => _t('никогда', 'never');
  String usedOf(String used, String total) =>
      _t('Использовано $used из $total', '$used of $total used');
  String expires(String date) => _t('до $date', 'until $date');
  String get latencyFailed => _t('нет ответа', 'no reply');
  String get subscriptionFailed =>
      _t('Не удалось загрузить подписку', 'Could not load the subscription');
  String get host => _t('Адрес', 'Host');
  String get port => _t('Порт', 'Port');
  String get badAddress =>
      _t('Проверьте адрес и порт', 'Check the address and the port');
  String get insecureSubscriptionQ => _t(
      'Адрес без шифрования: токен подписки уйдёт открытым текстом. Продолжить?',
      'The address is not encrypted: the subscription token would travel in the clear. Continue?');
  String get username => _t('Логин (необязательно)', 'Username (optional)');
  String get password => _t('Пароль (необязательно)', 'Password (optional)');
  String get qrPointCamera => _t('Наведите камеру на QR-код', 'Point the camera at a QR code');
  String get noShareLink => _t(
      'У этого сервера нет ссылки для экспорта',
      'This server has no link to share');

  // ---- routing
  String get routingDefault => _t('По умолчанию', 'By default');
  String get routeAllVpn => _t('Всё через VPN', 'Everything through VPN');
  String get routeAllVpnHint => _t(
      'Весь трафик идёт через VPN, кроме исключений ниже',
      'All traffic goes through the VPN, except the exceptions below');
  String get routeSelectedVpn => _t('Только выбранное', 'Only what I choose');
  String get routeSelectedVpnHint => _t(
      'Трафик идёт напрямую. Через VPN — только приложения и сайты, отмеченные ниже',
      'Traffic goes directly. Only the apps and sites marked below use the VPN');
  String get apps => _t('Приложения', 'Applications');
  String get appsHint => _t(
      'Выберите, как должно работать каждое приложение',
      'Choose how each application should connect');
  String get appsNeedTun => _t(
      'В режиме «Системный прокси» правила действуют только на программы, которые им пользуются. Чтобы управлять всеми приложениями, включите режим VPN.',
      'In “System proxy” mode the rules only reach programs that use the proxy. Switch to VPN mode to control every application.');
  String get noAppRules => _t(
      'Правил пока нет. Все приложения следуют настройке «По умолчанию».',
      'No rules yet. Every application follows the default above.');
  String get actionDirect => _t('Напрямую', 'Direct');
  String get actionVpn => _t('Через VPN', 'Via VPN');
  String get actionBlock => _t('Блок', 'Block');
  String get pickApp => _t('Выбор приложения', 'Choose an application');
  String get pickAppRunning => _t('Запущенные программы', 'Running programs');
  String get pickAppInstalled => _t('Установленные приложения', 'Installed applications');
  String get showSystemApps => _t('Показывать системные', 'Show system apps');
  String get browseExe => _t('Выбрать .exe файл…', 'Browse for an .exe…');
  String get appAlreadyAdded => _t('Уже в списке', 'Already added');
  String get matchByPath => _t('Только этот файл', 'This exact file only');
  String get matchByPathHint => _t(
      'Иначе правило действует на любую программу с таким именем',
      'Otherwise the rule covers any program with this file name');
  String get sites => _t('Сайты и адреса', 'Sites and addresses');
  String get ruDirect => _t('Российские сайты напрямую', 'Russian sites directly');
  String get ruDirectHint => _t(
      'Домены .ru, .рф, .su и российские IP-адреса идут мимо VPN: банки, Госуслуги и магазины работают как обычно',
      'Domains .ru, .рф, .su and Russian IP addresses bypass the VPN, so banks and local services work as usual');
  String get blockAds => _t('Блокировать рекламу', 'Block ads');
  String get addSite => _t('Добавить сайт или адрес', 'Add a site or address');
  String get siteExample => _t(
      'Например: youtube.com, 10.0.0.0/8 или слово из адреса',
      'For example: youtube.com, 10.0.0.0/8 or a keyword');
  String get kindSuffix => _t('домен и поддомены', 'domain and subdomains');
  String get kindKeyword => _t('слово в адресе', 'keyword');
  String get kindCidr => _t('IP-адрес', 'IP range');
  String get kindDomain => _t('точный домен', 'exact domain');

  // ---- settings
  String get secConnection => _t('Подключение', 'Connection');
  String get localPort => _t('Локальный порт прокси', 'Local proxy port');
  String get localPortHint => _t(
      'HTTP и SOCKS5 на одном порту (mixed)', 'HTTP and SOCKS5 on one port (mixed)');
  String get allowLan => _t('Доступ из локальной сети', 'Allow LAN access');
  String get allowLanHint => _t(
      'Другие устройства в сети смогут использовать этот прокси',
      'Other devices on your network can use this proxy');
  String get killSwitch => _t('Блокировать утечки (kill switch)', 'Block leaks (kill switch)');
  String get killSwitchHint => _t(
      'В режиме VPN не выпускать трафик мимо туннеля',
      'In VPN mode, do not let traffic escape the tunnel');
  String get ipv6 => _t('IPv6', 'IPv6');
  String get ipv6Hint => _t(
      'Отключите, если сервер не поддерживает IPv6: иначе возможны утечки',
      'Keep off unless your server supports IPv6, otherwise traffic may leak');
  String get tunStack => _t('Сетевой стек VPN', 'VPN network stack');
  String get secDns => _t('DNS', 'DNS');
  String get remoteDns => _t('DNS через VPN', 'DNS through the VPN');
  String get directDns => _t('DNS для прямых соединений', 'DNS for direct connections');
  String get dnsLocal => _t('Системный', 'System');
  String get fakeIp => _t('FakeIP', 'FakeIP');
  String get fakeIpHint => _t(
      'Быстрее и без подмены адресов провайдером. Работает в режиме VPN',
      'Faster and immune to DNS tampering. Works in VPN mode');
  String get secTunnels => _t('Проброс портов', 'Port forwarding');
  String get tunnelsHint => _t(
      'Локальный порт, который ведёт на заданный адрес через VPN',
      'A local port that leads to a fixed address through the VPN');
  String get addTunnel => _t('Добавить проброс', 'Add forward');
  String get tunnelTarget => _t('Адрес назначения', 'Destination');
  String get tunnelViaVpn => _t('Через VPN', 'Through the VPN');
  String get secApp => _t('Приложение', 'Application');
  String get language => _t('Язык', 'Language');
  String get langSystem => _t('Как в системе', 'System default');
  String get theme => _t('Тема', 'Theme');
  String get themeSystem => _t('Системная', 'System');
  String get themeLight => _t('Светлая', 'Light');
  String get themeDark => _t('Тёмная', 'Dark');
  String get launchAtStartup => _t('Запускать при входе в систему', 'Start with Windows');
  String get autoConnect => _t('Подключаться при запуске', 'Connect on launch');
  String get secUpdates => _t('Обновления', 'Updates');
  String get checkUpdatesAuto =>
      _t('Проверять обновления автоматически', 'Check for updates automatically');
  String version(String v) => _t('Версия $v', 'Version $v');
  String get checkNow => _t('Проверить сейчас', 'Check now');
  String get upToDate => _t('Установлена последняя версия', 'You are up to date');
  String updateAvailable(String v) => _t('Доступна версия $v', 'Version $v is available');
  String get installUpdate => _t('Установить', 'Install');
  String get whatsNew => _t('Что нового', 'What’s new');
  String get openReleasePage => _t('Открыть страницу загрузки', 'Open the download page');
  String get updateFailed => _t('Не удалось обновить', 'Update failed');
  String get secAbout => _t('О программе', 'About');
  String get aboutBody => _t(
      'Свободная программа под лицензией GPL-3.0. Работает на ядре sing-box.',
      'Free software under the GPL-3.0 licence. Powered by the sing-box core.');
  String get sourceCode => _t('Исходный код', 'Source code');
  String get logs => _t('Журнал', 'Log');
  String get logsEmpty => _t('Журнал пуст', 'The log is empty');
  String get logLevel => _t('Подробность журнала', 'Log detail');
  String get copyDiagnostics =>
      _t('Скопировать диагностику', 'Copy diagnostics');
  String get clear => _t('Очистить', 'Clear');
  String get runningAsAdmin =>
      _t('Запущено с правами администратора', 'Running as administrator');

  // ---- home (1.0.1)
  String get configs => _t('Конфигурации', 'Configurations');
  String get refreshSubs => _t('Обновить подписки', 'Refresh subscriptions');
  String get refreshShort => _t('Обновить', 'Refresh');
  String get pingAll => _t('Пинг всех', 'Ping all');
  String get pingShort => _t('Пинг', 'Ping');
  String get subsRefreshed => _t('Подписки обновлены', 'Subscriptions refreshed');
  String get noSubscriptions =>
      _t('Подписок пока нет', 'There are no subscriptions yet');
  String get deviceLimit => _t(
      'Достигнут лимит устройств для этой подписки. Отключите другое устройство в панели или обратитесь к администратору.',
      'The device limit of this subscription is reached. Remove another device in the panel or contact the administrator.');
  String get subscriptionUnreachable => _t(
      'Сервер подписки не отвечает. Проверьте подключение к интернету и адрес подписки.',
      'The subscription server does not answer. Check the internet connection and the address of the subscription.');
  String get subscriptionBadUrl => _t(
      'Это не адрес подписки. Он начинается с https:// и ведёт на сервер.',
      'This is not a subscription address. One starts with https:// and names a server.');
  String get deviceIdRequired => _t(
      'Сервер требует идентификатор устройства. Включите «Отправлять HWID» в настройках.',
      'The server requires a device id. Turn on “Send HWID” in settings.');
  String get support => _t('Поддержка', 'Support');
  String get themeToggle => _t('Светлая / тёмная тема', 'Light / dark theme');
  String get compactView => _t('Компактный вид', 'Compact view');
  String get fullView => _t('Обычный вид', 'Full view');
  String get modeProxyShort => _t('Прокси', 'Proxy');
  String get modeTunShort => _t('VPN', 'VPN');

  // ---- list groups and ping (1.0.2)
  String get collapse => _t('Свернуть', 'Collapse');
  String get expand => _t('Развернуть', 'Expand');
  String get pingMode => _t('Пинг серверов', 'Server ping');
  String get pingTcp => _t('TCP', 'TCP');
  String get pingUrl => _t('Через сервер', 'Through the server');
  String get pingTcpHint => _t(
      'Время соединения с самим сервером. Быстро и работает без подключения. WireGuard, Hysteria и TUIC не принимают TCP, для них замер идёт через сервер',
      'Time to connect to the server itself. Quick, and works while disconnected. WireGuard, Hysteria and TUIC do not accept TCP, so they are measured through the server');
  String get pingUrlHint => _t(
      'Время ответа сайта через каждый сервер: показывает задержку, которая будет в работе, но замер дольше',
      'Time of a real request through each server: the delay you will actually get, but slower to measure');

  // ---- connecting, DNS and logs (1.0.3)
  String get cancelConnecting => _t('Отменить подключение', 'Cancel connecting');
  String get tapToCancel => _t('Нажмите, чтобы отменить', 'Tap to cancel');
  String startTimeout(int seconds) => _t(
      'Ядро не запустилось за $seconds секунд. Подробности — в журнале: Настройки → Журнал.',
      'The core did not start within $seconds seconds. See the log for details: Settings → Log.');
  String get dnsManual => _t('Указать вручную…', 'Enter manually…');
  String dnsCustom(String value) => _t('Свой: $value', 'Custom: $value');
  String get dnsRemoteHint => _t(
      'IP-адрес или ссылка: 8.8.8.8 · tcp://8.8.8.8 · tls://dns.google · https://1.1.1.1/dns-query',
      'An IP address or a URL: 8.8.8.8 · tcp://8.8.8.8 · tls://dns.google · https://1.1.1.1/dns-query');
  String get dnsDirectHint => _t(
      'IP-адрес или ссылка: 77.88.8.8 · https://dns.yandex.ru/dns-query. Пусто — системный',
      'An IP address or a URL: 77.88.8.8 · https://dns.yandex.ru/dns-query. Empty for the system one');
  String get dnsNoAds => _t('без рекламы', 'blocks ads');
  String get dnsEncrypted => _t('шифрованный', 'encrypted');
  String get openLogFolder => _t('Открыть папку с журналом', 'Open the log folder');
  String get logLevelWarn => _t('только ошибки', 'errors only');
  String get logLevelInfo => _t('обычный', 'normal');
  String get logLevelDebug => _t('подробный', 'detailed');

  // ---- close dialog
  String get closeTitle => _t('Закрыть HeaNetwork?', 'Close HeaNetwork?');
  String get closeBody => _t(
      'Приложение может остаться в трее и держать соединение, либо завершиться полностью.',
      'The app can stay in the tray and keep the connection, or quit completely.');
  String get closeQuit => _t('Закрыть полностью', 'Quit completely');
  String get closeToTray => _t('Свернуть в трей', 'Minimize to tray');
  String get rememberChoice => _t('Запомнить выбор', 'Remember my choice');
  String get closeBehaviour => _t('При закрытии окна', 'When the window is closed');
  String get closeAsk => _t('Спрашивать', 'Ask');

  // ---- settings (1.0.1)
  String get animations => _t('Анимация фона', 'Animated background');
  String get animationsHint => _t(
      'Отключите на слабых устройствах или для экономии заряда',
      'Turn off on weak devices or to save battery');
  String get sendHwid => _t('Отправлять HWID в панель', 'Send HWID to the panel');
  String get sendHwidHint => _t(
      'Идентификатор устройства для лимита устройств в 3x-ui и ваш IP-адрес для статистики. Передаются только серверу подписки',
      'A device id for the 3x-ui device limit and your IP address for statistics. Sent to the subscription server only');
  String deviceId(String id) => _t('ID устройства: $id', 'Device id: $id');

  // ---- quick settings tile (Android)
  String get quickTile => _t('Кнопка в шторке', 'Quick settings tile');
  String get quickTileHint => _t(
      'Подключение одним нажатием из панели быстрых настроек — той, что открывается свайпом сверху',
      'Connect with one tap from the quick settings panel, the one a swipe down from the top opens');
  String get quickTileAdded =>
      _t('Кнопка добавлена в шторку', 'The tile is now in quick settings');
  String get quickTileAlready =>
      _t('Кнопка уже есть в шторке', 'The tile is already in quick settings');
  String get quickTileManual => _t(
      'Откройте шторку, нажмите «Изменить» (значок карандаша) и перетащите плитку HeaNetwork к остальным.',
      'Open quick settings, tap Edit (the pencil icon) and drag the HeaNetwork tile in with the others.');

  // ---- send / receive by QR
  String get receiveFromPhone => _t('Получить с телефона (QR)', 'Receive from a phone (QR)');
  String get receiveFromPhoneHint => _t(
      'Удобно для телевизора: отсканируйте код и вставьте подписку на телефоне',
      'Handy on a TV: scan the code and paste the subscription on your phone');
  String get receiveTitle => _t('Отправьте подписку с телефона', 'Send a subscription from your phone');
  String get receiveStep1 => _t(
      'Подключите телефон к той же сети Wi-Fi', 'Connect the phone to the same Wi-Fi network');
  String get receiveStep2 =>
      _t('Отсканируйте QR-код камерой телефона', 'Scan the QR code with the phone camera');
  String get receiveStep3 => _t(
      'Вставьте ссылку подписки или сервера и нажмите «Отправить»',
      'Paste the subscription or server link and press “Send”');
  String get receiveWaiting => _t('Ожидание телефона…', 'Waiting for the phone…');
  String get receiveNoNetwork => _t(
      'Устройство не подключено к локальной сети', 'This device is not connected to a local network');
  String get sendToDevice => _t('Отправить на другое устройство', 'Send to another device');
  String sendToDeviceBody(int n) => _t(
      'Отсканирован код HeaNetwork на другом устройстве. Отправить туда подписки и серверы ($n)?',
      'This is a HeaNetwork code from another device. Send your subscriptions and servers ($n) there?');
  String get send => _t('Отправить', 'Send');
  String get sent => _t('Отправлено', 'Sent');
  String get sendFailed => _t('Не удалось отправить', 'Could not send');

  // ---- session card, panel routing, app groups (1.0.6)
  String openConnections(int n) => _t('соединений: $n', 'connections: $n');
  String get subscription => _t('Подписка', 'Subscription');
  String routingFromPanel(String name) => _t(
      name.isEmpty ? 'Правила из панели' : 'Из панели: $name',
      name.isEmpty ? 'Rules from the panel' : 'From the panel: $name');
  String get panelRouting => _t('Маршрутизация из панели', 'Routing from the panel');
  String get panelRoutingHint => _t(
      'Правила, которые администратор задал в 3x-ui (формат Happ). Приходят вместе с подпиской и обновляются с ней. Ваши правила ниже имеют приоритет.',
      'Rules the administrator set in 3x-ui (Happ format). They arrive with the subscription and update with it. Your own rules below take priority.');
  String get panelRoutingNone => _t(
      'Подписка не прислала правил. Ссылку вида happ://routing/… можно вставить кнопкой справа.',
      'The subscription sent no rules. A happ://routing/… link can be pasted with the button on the right.');
  String get panelRoutingUse => _t('Применять правила из панели', 'Apply the panel rules');
  String get panelRoutingFromSub => _t('из подписки', 'from the subscription');
  String get panelRoutingFromLink => _t('из ссылки', 'from a link');
  String panelRoutingCounts(int direct, int proxy, int block) => _t(
      'Напрямую: $direct · Через VPN: $proxy · Блок: $block',
      'Direct: $direct · Via VPN: $proxy · Block: $block');
  String panelRoutingDefault(bool proxy) => _t(
      proxy ? 'Остальное — через VPN' : 'Остальное — напрямую',
      proxy ? 'Everything else through the VPN' : 'Everything else directly');
  String panelRoutingMissing(int n) => _t(
      'Списки ещё загружаются: $n. До загрузки эти правила не действуют.',
      'Lists still downloading: $n. Until then those rules do not apply.');
  String get panelRoutingImported =>
      _t('Маршрутизация из ссылки добавлена', 'Routing from the link was added');
  String get panelRoutingRemoved => _t('Маршрутизация из ссылки убрана', 'Routing from the link was removed');
  String get panelRoutingPaste => _t('Вставить ссылку', 'Paste a link');
  String get panelRoutingBadLink => _t(
      'В буфере нет ссылки happ://routing/…', 'The clipboard holds no happ://routing/… link');
  String processCount(int n) => _t(
      '$n ${_plural(n, 'процесс', 'процесса', 'процессов')}',
      '$n ${n == 1 ? 'process' : 'processes'}');
  String get logLevelNote => _t(
      'Показ меняется сразу. Более подробные строки ядро начнёт писать после переподключения.',
      'The view changes at once. The core starts writing more detailed lines after a reconnect.');
  String deviceModel(String model) => _t('Устройство: $model', 'Device: $model');

  // ---- servers: search, favourites, ads per server, this device (1.0.19)
  String get searchServers => _t('Поиск сервера', 'Search servers');
  String get searchNothing => _t('По этому запросу серверов нет', 'No server matches');
  String get searchReset => _t('Сбросить поиск', 'Clear the search');
  String get favourite => _t('В избранное', 'Add to favourites');
  String get unfavourite => _t('Убрать из избранного', 'Remove from favourites');
  String get favourited => _t('В избранном', 'Favourite');
  String get blockAdsAll =>
      _t('Блокировать рекламу на всех серверах', 'Block ads on every server');
  String get blockAdsPerServerHint => _t(
      'Задаётся у каждого сервера отдельно: меню ⋮ у сервера или у подписки',
      'Set on each server on its own: the ⋮ menu of a server, or of its subscription');
  String get thisDeviceTitle =>
      _t('Сервер указывает на само это устройство', 'A server points at this device itself');
  String get thisDeviceMark => _t('адрес самого устройства', 'address of this device');

  // ---- what the core says about a connection, in a person's words (1.0.19)
  String get realityTitle => _t(
      'Сервер не прошёл проверку Reality', 'The server failed the Reality check');
  String get realityHint => _t(
      'На запрос ответил не ваш сервер, а кто-то посередине: так выглядит подмена потока провайдером или ТСПУ. Соединение разорвано само, это защита. Если так происходит с каждым подключением, на сервере сменились ключ или короткий идентификатор либо сам сервер недоступен. Помогают другой сервер и меньше программ через VPN.',
      'Someone in the middle answered instead of your server: this is what a provider or a TSPU rerouting the flow looks like. The connection was dropped on purpose, as a protection. If every connection fails this way, the key or the short id on the server has changed, or the server is down. Another server and fewer applications through the VPN help.');
  String realitySeen(int n) => _t(
      'За этот сеанс проверку Reality не прошли $n ${_plural(n, 'соединение', 'соединения', 'соединений')}.',
      '$n ${n == 1 ? 'connection' : 'connections'} failed the Reality check this session.');
  String get thisDeviceHint => _t(
      'На этом устройстве по этому адресу ничего не отвечает. Проверьте адрес сервера: возможно, ссылка скопирована с самой панели.',
      'Nothing answers at that address on this device. Check the server address: the link may have been copied from the panel.');
  String thisDeviceWarning(String name) => _t(
      'Внимание: «$name» указывает на само это устройство. Через такой сервер интернет не появится, если только на нём не работает другой прокси.',
      'Warning: "$name" points at this device itself. It brings no internet unless another proxy runs on it.');

  // ---- backup copies (1.0.19)
  String get secBackup => _t('Резервная копия', 'Backup');
  String get backupHint => _t(
      'Всё, что есть в приложении, — одним текстом, с паролем или без',
      'Everything the app holds, as one text, with a password or without');
  String get backupBody => _t(
      'В копии серверы, подписки и настройки, включая ключи и пароли серверов. С паролем копия зашифрована (AES-256), без пароля лежит открытым текстом.',
      'The copy holds the servers, subscriptions and settings, server keys and passwords included. With a password it is encrypted (AES-256), without one it is plain text.');
  String get backupCreate => _t('Создать копию', 'Make a copy');
  String get backupRestore => _t('Восстановить из копии', 'Restore from a copy');
  String get backupPassword => _t('Пароль копии', 'Copy password');
  String get backupPasswordHint => _t(
      'Необязательно. С паролем копия шифруется, без — остаётся открытым текстом',
      'Optional. With a password the copy is encrypted, without one it stays plain text');
  String get backupCopy => _t('Скопировать', 'Copy');
  String get backupSaveFile => _t('Сохранить в файл…', 'Save to file…');
  String get backupCopied => _t('Копия в буфере обмена', 'The copy is in the clipboard');
  String get backupSaved => _t('Копия сохранена в файл', 'The copy was saved to a file');
  String get backupFileFailed => _t(
      'Не удалось записать или прочитать файл', 'Could not write or read the file');
  String get backupPasteHint =>
      _t('Текст копии — из буфера или из файла', 'The text of the copy, from the clipboard or a file');
  String get backupPaste => _t('Вставить', 'Paste');
  String get backupChooseFile => _t('Файл…', 'File…');
  String get backupRestoreAction => _t('Восстановить', 'Restore');
  String get backupRestoreQ => _t(
      'Восстановить эту копию? Текущие серверы, подписки и настройки будут заменены тем, что в ней.',
      'Restore this copy? The current servers, subscriptions and settings are replaced with what it holds.');
  String get backupRestored => _t('Копия восстановлена', 'The copy was restored');
  String get backupNotABackup => _t('Это не копия HeaNetwork', 'This is not a HeaNetwork backup');
  String get backupBadPassword => _t(
      'Не удалось расшифровать: проверьте пароль и целостность текста',
      'Could not decrypt: check the password and that the text is whole');

  // ---- tray
  String get trayShow => _t('Открыть HeaNetwork', 'Open HeaNetwork');
  String get trayConnect => _t('Подключить', 'Connect');
  String get trayDisconnect => _t('Отключить', 'Disconnect');
  String get trayQuit => _t('Выход', 'Quit');

  // ---- SSH client (Windows only, opt-in)
  String get sshFeatureTitle => _t('SSH-клиент (Терминал и SFTP)', 'SSH client (Terminal & SFTP)');
  String get sshFeatureHint => _t(
      'Показывает вкладку SSH в меню для управления серверами по SSH и SFTP',
      'Shows an SSH tab in the menu to manage servers over SSH and SFTP');
  String get sshHosts => _t('Хосты', 'Hosts');
  String get sshVpnServers => _t('Серверы VPN', 'VPN servers');
  String get sshAddHost => _t('Добавить хост', 'Add host');
  String get sshEditHost => _t('Изменить хост', 'Edit host');
  String get sshDeleteHostQ => _t('Удалить этот SSH-хост?', 'Delete this SSH host?');
  String get sshConnect => _t('Подключить', 'Connect');
  String get sshReconnect => _t('Переподключить', 'Reconnect');
  String get sshDisconnect => _t('Отключить', 'Disconnect');
  String get sshHostAddress => _t('Адрес (IP или домен)', 'Host (IP or domain)');
  String get sshPort => _t('Порт', 'Port');
  String get sshUsername => _t('Пользователь', 'Username');
  String get sshAuthPassword => _t('Пароль', 'Password');
  String get sshAuthKey => _t('SSH-ключ', 'SSH key');
  String get sshPassword => _t('Пароль', 'Password');
  String get sshPasswordKeepHint => _t('Оставьте пустым, чтобы не менять', 'Leave blank to keep');
  String get sshRouteGlobal => _t('Как глобально', 'Use global');
  String get sshRouteDirect => _t('Напрямую', 'Direct');
  String get sshRouteProxy => _t('Через VPN', 'Via VPN');
  String get sshRouteLabel => _t('Маршрут SSH', 'SSH route');
  String get sshTerminal => _t('Терминал', 'Terminal');
  String get sshSftp => _t('SFTP', 'SFTP');
  String get sshSnippets => _t('Сниппеты', 'Snippets');
  String get sshAddSnippet => _t('Новый сниппет', 'New snippet');
  String get sshEditSnippet => _t('Изменить сниппет', 'Edit snippet');
  String get sshSnippetCommand => _t('Команда', 'Command');
  String get sshSnippetAutoRun => _t('Выполнять сразу (Enter)', 'Run immediately (Enter)');
  String get sshKeys => _t('Ключи', 'Keys');
  String get sshNoKeys => _t('Нет сохранённых ключей', 'No saved keys');
  String get sshImportKeyFile => _t('Из файла…', 'From file…');
  String get sshPasteKey => _t('Вставить ключ', 'Paste key');
  String get sshGenerateKey => _t('Создать Ed25519', 'Generate Ed25519');
  String get sshPrivateKey => _t('Приватный ключ (PEM / OpenSSH)', 'Private key (PEM / OpenSSH)');
  String get sshPassphrase => _t('Кодовая фраза (если есть)', 'Passphrase (optional)');
  String get sshCopyPublicKey => _t('Скопировать публичный ключ', 'Copy public key');
  String get sshNoHosts => _t('Нет SSH-хостов. Добавьте вручную или выберите сервер VPN ниже.',
      'No SSH hosts yet. Add one manually or pick a VPN server below.');
  String get sshConfigureForVpn => _t('Настроить SSH', 'Set up SSH');
  String get sshConnecting => _t('Подключение…', 'Connecting…');
  String get sshConnected => _t('Подключено', 'Connected');
  String get sshDisconnected => _t('Отключено', 'Disconnected');
  String get sshVpnNotRunning => _t(
      'VPN не подключён: включите VPN или переключите маршрут SSH на «Напрямую»',
      'VPN is not connected: turn VPN on or switch SSH route to Direct');
  String get sshHostKeyTitle => _t('Проверка ключа сервера', 'Verify server host key');
  String get sshHostKeyChangedTitle => _t('ВНИМАНИЕ: ключ сервера изменился!', 'WARNING: server host key changed!');
  String sshHostKeyBody(String host, String type, String fp, String? oldFp) => oldFp == null
      ? _t(
          'Первое подключение к $host.\nТип: $type\nОтпечаток: $fp\n\nДоверять этому серверу и сохранить отпечаток?',
          'First connection to $host.\nType: $type\nFingerprint: $fp\n\nTrust this server and save its fingerprint?')
      : _t(
          'Ключ сервера $host отличается от сохранённого!\nБыло: $oldFp\nСтало: $fp\n\nВозможна подмена (MITM) или переустановка ОС. Продолжить и обновить ключ?',
          'Host key for $host differs from the saved one!\nSaved: $oldFp\nNew: $fp\n\nThis may mean a MITM attack or an OS reinstall. Continue and update?');
  String get sshTrust => _t('Доверять', 'Trust');

  // ---- SFTP
  String get sftpUp => _t('Вверх', 'Up');
  String get sftpUpload => _t('Загрузить', 'Upload');
  String get sftpDownload => _t('Скачать', 'Download');
  String get sftpOpenEditor => _t('Открыть в редакторе ОС', 'Open in OS editor');
  String get sftpNewFolder => _t('Новая папка', 'New folder');
  String get sftpFolderName => _t('Имя папки', 'Folder name');
  String get sftpNewName => _t('Новое имя', 'New name');
  String sftpDeleteQ(String name) => _t('Удалить «$name»?', 'Delete "$name"?');
  String get sftpEmptyDir => _t('Папка пуста', 'Folder is empty');
  String get sftpShowHidden => _t('Скрытые файлы', 'Hidden files');
  String sftpDownloaded(String name) => _t('Скачано: $name', 'Downloaded: $name');
  String sftpUploaded(String name) => _t('Загружено: $name', 'Uploaded: $name');
  String sftpModifiedBanner(String name) => _t(
      'Файл «$name» изменён в редакторе', 'File "$name" was modified in editor');
  String get sftpUploadBack => _t('Загрузить обратно', 'Upload changes');

  // ---- SSH transfer (LAN & file/link)
  String get sshTransfer => _t('Передать / Принять', 'Send / Receive');
  String get sshSend => _t('Отправить', 'Send');
  String get sshReceive => _t('Принять', 'Receive');
  String get sshTransferLan => _t('По локальной сети (LAN)', 'Over LAN');
  String get sshTransferFileLink => _t('Файл / Ссылка', 'File / Link');
  String get sshTransferSelect => _t('Что передать', 'What to include');
  String get sshIncludeSecrets => _t('Включить пароли и приватные ключи', 'Include passwords and private keys');
  String get sshPinCode => _t('PIN / Пароль шифрования', 'Encryption PIN / Password');
  String get sshStartLanSend => _t('Начать раздачу в LAN', 'Start LAN broadcast');
  String get sshStopLanSend => _t('Остановить', 'Stop');
  String sshLanReady(String addr, String pin) => _t(
      'Ожидание другого HeaNetwork в сети…\nАдрес: $addr\nPIN-код: $pin',
      'Waiting for another HeaNetwork on LAN…\nAddress: $addr\nPIN: $pin');
  String get sshLanNoNetwork => _t('Локальная сеть не найдена', 'No local network address found');
  String get sshLanScanning => _t('Поиск HeaNetwork в локальной сети…', 'Looking for HeaNetwork on LAN…');
  String get sshLanManualAddr => _t('Или введите адрес вручную (IP:порт)', 'Or enter address manually (IP:port)');
  String get sshSaveBundle => _t('Сохранить .heassh…', 'Save .heassh…');
  String get sshCopyLink => _t('Копировать ссылку', 'Copy link');
  String get sshOpenBundle => _t('Открыть .heassh…', 'Open .heassh…');
  String get sshPasteLinkHint => _t('Вставьте heanetwork://… или текст пакета', 'Paste heanetwork://… or bundle text');
  String get sshImportAction => _t('Импортировать', 'Import');
  String get sshBadBundleOrPin => _t('Неверный PIN/пароль или повреждённый пакет', 'Wrong PIN/password or invalid bundle');
  String sshImportPreview(int hosts, int keys, int snippets) => _t(
      'Будет добавлено (без замены существующих): хостов — $hosts, ключей — $keys, сниппетов — $snippets',
      'Will add (without overwriting existing): $hosts hosts, $keys keys, $snippets snippets');
  String sshImportedDone(int hosts, int keys, int snippets) => _t(
      'Импортировано: хостов — $hosts, ключей — $keys, сниппетов — $snippets',
      'Imported: $hosts hosts, $keys keys, $snippets snippets');
  String get sshSentOk => _t('Пакет успешно передан', 'Bundle sent successfully');

  String _plural(int n, String one, String few, String many) {
    final m10 = n % 10;
    final m100 = n % 100;
    if (m10 == 1 && m100 != 11) return one;
    if (m10 >= 2 && m10 <= 4 && (m100 < 12 || m100 > 14)) return few;
    return many;
  }
}
