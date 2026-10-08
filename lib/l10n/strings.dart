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

  String _t(String r, String e) => _ru ? r : e;

  // ---- navigation
  String get navHome => _t('Главная', 'Home');
  String get navServers => _t('Серверы', 'Servers');
  String get navRouting => _t('Маршруты', 'Routing');
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
  String get apply => _t('Применить', 'Apply');
  String get search => _t('Поиск', 'Search');
  String get name => _t('Название', 'Name');
  String get ok => _t('Понятно', 'OK');
  String get refresh => _t('Обновить', 'Refresh');
  String get later => _t('Позже', 'Later');

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
  String get currentServer => _t('Сервер', 'Server');
  String get autoSelect => _t('Автовыбор', 'Auto-select');
  String autoSelectOf(String sub) =>
      _t('Лучший сервер из «$sub»', 'Best server of “$sub”');
  String get mode => _t('Режим', 'Mode');
  String get modeProxy => _t('Системный прокси', 'System proxy');
  String get modeTun => _t('VPN (весь трафик)', 'VPN (all traffic)');
  String get modeProxyHint => _t(
      'Только программы, которые используют системный прокси: браузеры и большинство приложений. Права администратора не нужны.',
      'Only programs that honour the system proxy: browsers and most apps. No administrator rights needed.');
  String get modeTunHint => _t(
      'Весь трафик компьютера, включая игры и программы без поддержки прокси. Нужны права администратора.',
      'All traffic of this computer, including games and programs without proxy support. Needs administrator rights.');
  String get download => _t('Загрузка', 'Download');
  String get upload => _t('Отдача', 'Upload');
  String get sessionTraffic => _t('За сеанс', 'This session');
  String get routingSummaryAll => _t('Весь трафик через VPN', 'All traffic through VPN');
  String get routingSummarySelected =>
      _t('Через VPN только выбранное', 'Only selected traffic through VPN');
  String routingExceptions(int n) => _t(
      '$n ${_plural(n, 'исключение', 'исключения', 'исключений')}',
      '$n ${n == 1 ? 'exception' : 'exceptions'}');
  String get errorTitle => _t('Не удалось подключиться', 'Could not connect');
  String get connectionLost => _t('Соединение прервано', 'Connection lost');
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
  String get testAll => _t('Проверить задержку', 'Test latency');
  String get clipboardEmpty => _t('Буфер обмена пуст', 'The clipboard is empty');
  String imported(int n) => _t(
      'Добавлено: $n ${_plural(n, 'сервер', 'сервера', 'серверов')}',
      'Added $n ${n == 1 ? 'server' : 'servers'}');
  String get nothingImported =>
      _t('Не удалось распознать ни одного сервера', 'No server could be recognised');
  String skipped(int n) => _t('Пропущено: $n', 'Skipped: $n');
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
  String get proxyType => _t('Тип', 'Type');
  String get host => _t('Адрес', 'Host');
  String get port => _t('Порт', 'Port');
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
  String get addApp => _t('Добавить приложение', 'Add application');
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
  String get blockAdsHint => _t(
      'Отклонять запросы к известным рекламным и следящим доменам',
      'Reject requests to known advertising and tracking domains');
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
  String get secAntiDpi => _t('Защита от блокировок (DPI / ТСПУ)', 'Censorship resistance (DPI)');
  String get antiDpiIntro => _t(
      'Маскирует начало TLS-соединения, чтобы оборудование провайдера не распознало VPN. Reality, XHTTP и AmneziaWG настраиваются в самом сервере и работают всегда.',
      'Disguises the start of the TLS connection so that provider equipment does not recognise the VPN. Reality, XHTTP and AmneziaWG come from the server profile and are always on.');
  String get presetOff => _t('Выкл', 'Off');
  String get presetBalanced => _t('Авто', 'Auto');
  String get presetStrong => _t('Усиленная', 'Strong');
  String get presetCustom => _t('Вручную', 'Custom');
  String get presetOffHint =>
      _t('Профиль сервера используется как есть', 'The server profile is used as is');
  String get presetBalancedHint => _t(
      'Разбиение TLS-записей и отпечаток браузера Chrome. Не замедляет соединение',
      'TLS record splitting and a Chrome browser fingerprint. No slowdown');
  String get presetStrongHint => _t(
      'Дополнительно дробит TCP-пакеты и обрабатывает прямые соединения. Подключение может стать медленнее',
      'Also splits TCP segments and treats direct connections. Connecting may get slower');
  String get tlsRecordFragment => _t('Разбивать TLS-записи', 'Split TLS records');
  String get tlsFragment => _t('Дробить TCP-пакеты', 'Split TCP segments');
  String get tlsFragmentHint => _t(
      'Сильнее, но медленнее. Включайте, если не помогло разбиение записей',
      'Stronger but slower. Try it when record splitting is not enough');
  String get fingerprint => _t('Отпечаток браузера (uTLS)', 'Browser fingerprint (uTLS)');
  String get fingerprintKeep => _t('Как в профиле', 'As in the profile');
  String get directFragment =>
      _t('Обрабатывать прямые соединения', 'Also treat direct connections');
  String get directFragmentHint => _t(
      'Помогает сайтам, которые замедляют, а не блокируют',
      'Helps with sites that are throttled rather than blocked');
  String get spoofSni => _t('Подмена SNI', 'SNI spoofing');
  String get spoofSniHint => _t(
      'Отправлять ложное приветствие с разрешённым доменом. Только режим администратора',
      'Send a decoy hello carrying an allowed domain. Administrator mode only');
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
  String get minimizeToTray => _t('Сворачивать в трей при закрытии', 'Close to tray');
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
  String get deviceIdRequired => _t(
      'Сервер требует идентификатор устройства. Включите «Отправлять HWID» в настройках.',
      'The server requires a device id. Turn on “Send HWID” in settings.');
  String get support => _t('Поддержка', 'Support');
  String get themeToggle => _t('Светлая / тёмная тема', 'Light / dark theme');
  String get compactView => _t('Компактный вид', 'Compact view');
  String get fullView => _t('Обычный вид', 'Full view');
  String get modeProxyShort => _t('Прокси', 'Proxy');
  String get modeTunShort => _t('VPN', 'VPN');
  String get total => _t('Всего', 'Total');

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
      'Идентификатор устройства для лимита устройств в 3x-ui. Передаётся только серверу подписки',
      'A device id for the 3x-ui device limit. Sent to the subscription server only');
  String deviceId(String id) => _t('ID устройства: $id', 'Device id: $id');
  String get profileWins => _t(
      'Параметры, заданные в самом сервере или подписке, всегда имеют приоритет: приложение только добавляет недостающее.',
      'Settings carried by the server or subscription always take priority: the app only adds what is missing.');

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

  // ---- tray
  String get trayShow => _t('Открыть HeaNetwork', 'Open HeaNetwork');
  String get trayConnect => _t('Подключить', 'Connect');
  String get trayDisconnect => _t('Отключить', 'Disconnect');
  String get trayQuit => _t('Выход', 'Quit');

  String _plural(int n, String one, String few, String many) {
    final m10 = n % 10;
    final m100 = n % 100;
    if (m10 == 1 && m100 != 11) return one;
    if (m10 >= 2 && m10 <= 4 && (m100 < 12 || m100 > 14)) return few;
    return many;
  }
}
