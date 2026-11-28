# История версий

Раздел версии публикуется как описание релиза и показывается в приложении
в блоке «Что нового», поэтому здесь простой текст без оформления.

## 1.0.24

- Выделенный HTTP-прокси на вкладке «Antigravity» (Windows): введите прокси в формате user:pass@host:port (поддерживаются также http://, https:// и host:port), и трафик Antigravity будет автоматически направляться через него сразу при запуске HeaNetwork — даже когда основной VPN выключен.
- Полная независимость от основного VPN: можно одновременно использовать свой HTTP-прокси для Antigravity и основной VPN-сервер для остального трафика, а также менять или отключать прокси в любой момент. Когда выделенный прокси выключен, сохраняется прежний режим работы через основной VPN.
- Поле ввода скрывает учётные данные по умолчанию (с кнопкой показа), в статусе отображается только host:port. DNS для доменов Antigravity резолвится по DoH через указанный HTTP-прокси, UDP/QUIC для Antigravity отклоняется для мгновенного перехода на TCP, а проверка соединения работает и без VPN с распознаванием ошибки авторизации HTTP 407.

English: added a dedicated HTTP(S) proxy option on the Windows "Antigravity" tab — enter a proxy in user:pass@host:port (or http://, https://, host:port) format and Antigravity traffic routes through it automatically on app launch, even while the main VPN is off. It stays completely independent when the main VPN is connected (Antigravity uses its HTTP proxy while the rest of the system uses your VPN server), can be edited or disabled at any time, and falls back to the main VPN when turned off. Credentials are masked by default with a visibility toggle and only host:port is shown in the status tile. Antigravity DNS resolves over DoH through the HTTP proxy, UDP/QUIC is rejected for immediate TCP fallback, and the connection check now works without VPN and detects HTTP 407 authentication errors.

## 1.0.23

- Поддержка Antigravity на Windows, по умолчанию выключена: переключатель в настройках добавляет вкладку «Antigravity» и направляет через VPN домены Antigravity (cloudcode-pa.googleapis.com, daily-cloudcode-pa.googleapis.com, aicode.googleapis.com), их DNS и процессы Antigravity.exe, agy.exe и language_server — Language Server часто игнорирует системный прокси, поэтому всё идёт через туннель. Свои правила на странице «Маршруты» имеют приоритет над встроенными.
- На вкладке — статус маршрутизации и проверка соединения: HTTPS-запрос через ваш текущий VPN-сервер без данных аккаунта, с распознаванием ответа «регион не поддерживается». Сетевой режим не обходит клиентскую проверку ineligible: при региональном отказе выберите сервер в поддерживаемой стране и переподключитесь. Language Server может не использовать системный прокси — выберите режим «VPN (весь трафик)» и переподключитесь.

English: added opt-in Antigravity support for Windows — a Settings switch reveals an "Antigravity" tab and routes Antigravity domains (cloudcode-pa.googleapis.com, daily-cloudcode-pa.googleapis.com, aicode.googleapis.com), their DNS, and the Antigravity.exe / agy.exe / language_server processes through the VPN; the Language Server often ignores the system proxy, so everything goes through the tunnel. Your own Routing rules take priority over the built-in ones. The tab shows routing status and a connection check — an HTTPS request through your current VPN server with no account data, recognizing the "unsupported location" refusal. Network mode does not bypass the client-side ineligible check: on a location error, pick a server in a supported country and reconnect. The Language Server may ignore the system proxy — select "VPN (all traffic)" mode and reconnect.

## 1.0.22

- Подсветка ключевых данных в SSH-терминале как в Termius: IPv4 и MAC-адреса автоматически выделяются розовым, ошибки и отказы (Error, Fail, Denied, Timeout и др.) — красным, предупреждения и статусы (Yes, Warning, OK, Active и др.) — жёлтым, даже в обычном нераскрашенном выводе и при наборе команд. Серверные ANSI-цвета и полноэкранные приложения (vim, htop, nano) не затрагиваются; подсветку можно включать и отключать кнопкой на панели SSH.
- Тема Termius Dark (тёмно-синий фон, зелёный текст, розовые IP, красные ошибки, жёлтые статусы) стала темой терминала по умолчанию.

English: added Termius-style client-side keyword highlighting in the Windows SSH terminal — IPv4 and MAC addresses appear in pink/magenta, errors and failures in red, and warnings/confirmations (Yes, Warning, OK, Active, etc.) in yellow, including during char-by-char typing, while leaving server ANSI colors and full-screen TUI apps (vim, htop, nano) intact, with a toolbar toggle. Termius Dark is now the default terminal color theme.

## 1.0.21

- Цветовые темы для SSH-терминала на Windows (как в Termius): добавлены 10 готовых палитр — Default Dark, Dracula, One Dark, Nord, Tokyo Night, Catppuccin Mocha, Gruvbox Dark, Monokai, Solarized Dark и Solarized Light. Переключатель с предпросмотром цветов доступен прямо на панели экрана SSH, выбор сохраняется в настройках и попадает в резервную копию.

English: added 10 Termius-style color themes for the Windows SSH terminal — Default Dark, Dracula, One Dark, Nord, Tokyo Night, Catppuccin Mocha, Gruvbox Dark, Monokai, Solarized Dark, and Solarized Light. A palette picker with colour swatches sits right in the SSH toolbar and persists in settings and backups.

## 1.0.20

- Встроенный SSH-клиент на Windows: многовкладочный терминал, панель сниппетов (быстрых команд) и менеджер SSH-ключей с генерацией Ed25519 и проверкой отпечатка сервера (TOFU). Функция выключена по умолчанию и включается тумблером в настройках («Приложение → SSH-клиент»); на Android не отображается.
- В список хостов автоматически подтягиваются уже добавленные VPN-серверы: достаточно один раз указать логин и пароль или ключ, а обновление подписки не сбрасывает привязку. Переключатель маршрута позволяет подключаться по SSH напрямую (в обход TUN) или через активный VPN-туннель.
- Встроенный SFTP-файловый менеджер поверх активного SSH-соединения: просмотр каталогов, загрузка, скачивание, создание папок, переименование, удаление и открытие файлов в редакторе ОС с предложением загрузить изменения обратно после сохранения.
- Зашифрованная (AES-256-GCM) передача хостов, ключей и сниппетов между экземплярами HeaNetwork по локальной сети с 6-значным PIN-кодом или через файл .heassh / ссылку heanetwork:// с аккуратным слиянием без замены существующих записей. Пароли и приватные ключи на диске защищены через Windows DPAPI.
- Обновлена контрольная сумма списка маршрутизации geosite-category-ru.

English: opt-in built-in SSH client on Windows (off by default in Settings, hidden on Android) with a tabbed terminal, command snippets, Ed25519 key manager, and TOFU host key verification. Existing VPN servers appear ready for one-time SSH setup, with a Direct (bypassing TUN) vs Via VPN route switch. Includes an SFTP browser over the active SSH session with open-in-OS-editor and one-click upload back on save. Hosts, keys, and snippets can be transferred between HeaNetwork instances encrypted with AES-256-GCM over LAN using a 6-digit PIN or via .heassh files and heanetwork:// links, merging without overwriting; local secrets are protected with Windows DPAPI. Updated the pinned geosite-category-ru rule-set checksum.

## 1.0.19

- Резервная копия всего приложения: серверы, подписки, маршрутизация и настройки сохраняются одним текстом в буфер обмена или файл и восстанавливаются на другом устройстве. Пароль шифрует копию по AES-256; без пароля она остаётся открытым текстом. Неверный пароль, повреждённая или неполная копия не меняет текущие данные.
- В списке из восьми и более серверов появляется поиск по названию, адресу и описанию. Любой сервер можно добавить в избранное — он держится в начале своей группы и не теряет отметку при обновлении подписки.
- Блокировка рекламы теперь задаётся отдельно для каждого сервера, а для всей подписки — одним пунктом меню. Прежний общий переключатель при обновлении автоматически переносится на все имеющиеся серверы.
- Ссылки на localhost и адреса самого устройства отмечаются при импорте и в списке: через такой сервер интернет не появится, если на устройстве не работает другой прокси. Повторные ошибки Reality и соединения с адресом самого устройства получили понятные объяснения на главном экране и в журнале.
- При маршрутизации российских сайтов напрямую Google и YouTube на российских кэширующих адресах снова идут через VPN: по IP такие адреса выглядят российскими, хотя сами сервисы должны оставаться в туннеле.
- Xray-core обновлён до 26.11.9, Flutter — до 3.47.9, Go для Android-ядра — до 1.26.11. Сборка умеет подписывать установщик Windows, если в репозитории настроен сертификат.

English: the whole app can be backed up as one text to the clipboard or a file and restored elsewhere, optionally encrypted with AES-256; a wrong password or a damaged or incomplete copy changes nothing. Server lists of eight or more get search, and favourites stay at the top of their group across subscription refreshes. Ad blocking is now a per-server choice, with a whole-subscription action and automatic migration of the old global switch. Servers pointing at localhost or this device itself are marked at import and in the list, while repeated Reality and local-address failures get plain-language explanations. With Russian sites routed directly, Google and YouTube names at Russian cache addresses go through the VPN. Xray-core is 26.11.9, Flutter 3.47.9 and the Android core's Go 1.26.11; the workflow can sign the Windows installer when a certificate is configured.

## 1.0.18

- Серверы с транспортом h2 из JSON-подписки больше не импортируются «успешно» без своих настроек: раньше адрес хоста и путь терялись, и такой сервер молча не подключался. Настройки ранних данных WebSocket из JSON-конфигов тоже больше не теряются.
- Если Xray-core (серверы MASQUE и XDRIVE) умирал, пока ядро ещё запускалось, приложение показывало «Подключено» с мёртвым туннелем. Теперь запуск честно заканчивается ошибкой.
- Списки маршрутизации, о которых говорит новая подписка, скачиваются сразу при её добавлении, а не при первом обновлении: раньше первое подключение жаловалось на «пропущенную маршрутизацию», хотя правила в подписке были.
- На Android, если VPN поднял виджет, а ядро к моменту открытия приложения уже умерло, скорость и счётчики больше не стоят на нуле весь сеанс.
- Запись подписки с пустым паролем или UUID теперь отклоняется при импорте с внятной ошибкой, а не падает ядром при подключении. Порт текстом в настройках XHTTP и неполный контейнер Amnezia-ключа больше не срывают импорт остальных серверов, а WARP-конфиги старого формата sing-box сохраняют свои reserved-байты, без которых сервер отказывает в рукопожатии.
- Ошибка TLS-соединения с панелью показывается как «сервер недоступен», а не сырым текстом исключения. Любой сбой сохранения настроек больше не отключает все последующие сохранения до перезапуска приложения.
- Измерение задержки: случайная коллизия свободных портов больше не принимается за неработающий сервер, из-за которой разом все серверы могли показаться недоступными. Списки маршрутизации, обновлённые после сбоя ядра, сразу отражаются на странице «Маршруты».

English: servers with the h2 transport from a JSON subscription no longer import without their host and path — such a server used to connect to nothing, silently; WebSocket early-data settings from JSON configs are kept too. An Xray-core that died while the core was still starting no longer leaves a "connected" badge over a dead tunnel. The routing lists a new subscription refers to are downloaded when it is added, not at the first refresh, so the first connect no longer complains about skipped routing. On Android, a VPN started by the widget whose engine has since died no longer shows zeroed speed for the whole session. Entries with empty credentials are refused at import with a clear message instead of a core failure at connect; a text port in XHTTP download settings and an incomplete Amnezia container no longer cost the rest of the import, and old-format WARP configs keep their reserved bytes. A TLS failure to the panel reads as "unreachable", a failed settings save no longer disables every later save until a restart, and a port collision in the latency test no longer passes for dead servers.

## 1.0.17

- Отключение во время установки соединения — последнее слово. Раньше, если нажать «Отключить», пока приложение проверяло туннель (до нескольких секунд после старта), ядро могло подняться снова уже после отключения: приложение показывало «Подключено», хотя пользователь выключал VPN. Теперь любое отключение останавливает установку соединения на любом шаге.
- На Android выбор сервера из виджета или плитки в момент, когда VPN включается или выключается, больше не теряется: раньше такой запрос просто отбрасывался, и виджет приходилось нажимать ещё раз.
- Одна повреждённая запись в подписке или в JSON-конфиге больше не срывает весь импорт: нечитаемый сервер пропускается, остальные добавляются. Ссылка VLESS с Reality без публичного ключа и Amnezia-ключ с неправдоподобным размером отклоняются сразу с внятной ошибкой, а не падением ядра при подключении.
- Подписка, удалённая во время фонового обновления, не возвращается вместе со своими серверами. Адрес подписки без шифрования (http://) теперь сопровождается предупреждением: токен подписки уходит открытым текстом.
- Приложение с включённым VPN больше не перестраивает все свои страницы дважды в секунду ради показа скорости: обновляются только цифры, которые видны. Меньше нагрузки на процессор и батарею — заметнее всего на телевизоре и на длинных списках серверов.
- На Android исправлена утечка памяти, если смахнуть приложение, пока VPN работает, а состояние виджета теперь записывается атомарно. Плитка и виджет, если сами подключиться не смогли, открывают приложение вместо тихого «ничего не произошло».
- Под капотом: ошибки прямо в диалоге ручного добавления сервера, обновлялка не считает лимит запросов GitHub за ошибку, мелкие правки стабильности.

English: turning the VPN off while a connection is still being set up is now final — the core can no longer come back up after the user disconnected. On Android, picking a server from the widget or the tile during a start or stop is no longer silently dropped. One malformed entry in a subscription or JSON import no longer costs the whole import; a Reality link without a public key and an implausibly-sized Amnezia key are refused up front with a clear message. A subscription deleted during a background refresh stays deleted; plain-http subscription addresses now warn about the token travelling unencrypted. While connected, the app no longer rebuilds all its pages twice a second for the live speed numbers — less CPU and battery, most visible on TV and long server lists. On Android: fixed an engine memory leak when the app is swiped away with the VPN up, the widget state is written atomically, and the tile/widget open the app when they could not connect by themselves.

## 1.0.16

- На странице журнала появилась кнопка «Скопировать диагностику»: она копирует одно сообщение с версией приложения, платформой, режимом работы и последними строками журнала, из которых убраны UUID, пароли и ключи подписки. Самый быстрый способ рассказать о проблеме.
- Под капотом: код состояния приложения разделён на модули, а скачиваемые списки маршрутизации теперь сверяются по контрольным суммам.

English: the log page has a "Copy diagnostics" button: one paste-ready message with the app version, platform, mode and the last log lines, scrubbed of UUIDs, passwords and subscription keys — the quickest way to report a problem. Under the hood, the app state is split into modules, and the routing lists it downloads are now verified against pinned checksums.

## 1.0.15

- Срочное обновление безопасности: Xray-core, через который на Windows работают серверы MASQUE и XDRIVE, обновлён до 26.10.21. Версию 26.10.17 из прошлого выпуска разработчики Xray отозвали: в ней были корневые сертификаты, через которые проходят цепочки, признанные ненадёжными. Новая версия такие цепочки отвергает.
- Ядро для Android собрано на Go 1.26.10 и тоже отвергает эти цепочки сертификатов.

English: urgent security update. Xray-core, which carries MASQUE and XDRIVE servers on Windows, is 26.10.21: Xray withdrew 26.10.17, which shipped root certificates over chains that are no longer trusted, and the new version refuses those chains. The Android core is built with Go 1.26.10 and refuses them too.

## 1.0.14

- MASQUE и XDRIVE из 3x-ui 3.10 на Windows: такие серверы теперь подключаются через Xray-core 26.10.17. Он поставляется вместе с приложением и запускается только для этих серверов, остальные работают как раньше. Панель отдаёт MASQUE и XDRIVE только в JSON-подписке: добавьте в приложение её ссылку.
- На Android такие серверы пока не поддерживаются и, как прежде, названы под подпиской.
- Задержку до серверов MASQUE и XDRIVE приложение не измеряет, а его защита от блокировок к ним не применяется: Xray-core делает то, что задано в панели.
- Если панель присылает для такого сервера allowInsecure, приложение его убирает: Xray-core 26.10 с ним не запускается. Сертификат сервера проверяется.

English: MASQUE and XDRIVE servers from 3x-ui 3.10 connect on Windows through Xray-core 26.10.17, shipped with the app and started only for them (the panel serves them in its JSON subscription only); Android still lists them as left out. Their latency is not measured and the app's anti-DPI measures do not apply to them; an allowInsecure the panel sends for them is dropped, since Xray-core 26.10 refuses to start with it.

## 1.0.13

- Ядро обновлено до sing-box-extended 2.7.3 (sing-box 1.14.3): исправления XHTTP, перенесённые из Xray, и обновления WireGuard, Sudoku и MTProxy.
- XHTTP: настройки места и имени идентификатора сеанса (sessionIDPlacement, sessionIDKey) теперь читаются под теми именами, которые пишут Xray и 3x-ui; раньше они терялись и такой сервер не подключался.
- Ссылки VMess с XHTTP: режим, заполнение и остальные настройки XHTTP, которые 3x-ui кладёт прямо в ссылку, больше не теряются.

English: the core is now sing-box-extended 2.7.3 (sing-box 1.14.3); XHTTP session settings are read under the names Xray and 3x-ui use (sessionIDPlacement, sessionIDKey); VMess links keep their XHTTP mode, padding and other settings.

## 1.0.12

- Подписка снова обновляется на устройствах, названных по-русски. С версии 1.0.6 приложение сообщает панели имя устройства, и если в нём были буквы не латиницей (например, «Samsung S24 Ultra пользователя Седой»), загрузка подписки прерывалась ошибкой «Invalid HTTP header field value». Теперь панели передаётся то, что можно передать («Samsung S24 Ultra»), а запрос уходит в любом случае.

English: subscriptions update again on devices named in another alphabet. Since 1.0.6 the app tells the panel the device's name, and a name with non-Latin letters made every subscription update fail with "Invalid HTTP header field value"; what HTTP can carry of the name is sent now, and the request goes out either way.

## 1.0.11

- «Переподключить» после переключения в режим VPN без прав администратора больше не обрывает соединение: приложение спрашивает, как поступить, а текущее соединение остаётся. Раньше оно разрывалось, и связь пропадала без объяснений.
- Ошибка на последнем шаге подключения больше не оставляет соединение наполовину включённым, а отключение срабатывает, даже если не удалось вернуть настройки системного прокси.
- Удаление сервера или подписки, через которые идёт соединение, предлагает переподключиться.
- Android: приложение не остаётся навсегда в «Подключение…» после сбоя запуска и останавливает VPN, который не поднялся за 30 секунд.
- Маршрутизация из панели: опечатка в названии списка сайтов больше не блокирует локальную сеть, а списки, запрошенные во время другой загрузки, тоже скачиваются.
- Импорт: файл WireGuard с неверным адресом сервера и ключ Amnezia без туннеля дают понятное сообщение вместо сбоя.
- Файлы настроек с неверным содержимым (от другой версии или после ручной правки) больше не мешают приложению запуститься.
- Подписки: недоступный сервер называется недоступным вместо технической ошибки, а адрес можно вводить без https://.
- Обновление: зависшая загрузка прерывается через 30 секунд, а уже установленные установщики удаляются с диска.

English: fixes from a review of the whole app. Reconnecting into VPN mode without administrator rights no longer drops the connection in use; a connection is never left half made; deleting the server in use asks for a reconnect; Android no longer stays "connecting" for good after a failed start; a typo in a panel's routing profile no longer blocks the local network; broken WireGuard files, Amnezia keys and settings files are handled instead of failing; an unreachable subscription server is said to be so, and an address may be typed without https://; a stalled update download gives up, and installers that have been installed are removed.

## 1.0.10

- Совместимость с 3x-ui 3.10. Протокол MASQUE и транспорт XDRIVE ядро приложения пока не поддерживает: такие серверы теперь названы под подпиской вместе с причиной, а не пропадают молча. Раньше один сервер с XDRIVE в JSON-подписке не давал обновить подписку целиком.
- Hysteria 2 из JSON-подписки: смена портов (маска udphop и прежняя запись) и обфускация gecko. Gecko читается и из ссылок.
- Описание сервера, которое панель дописывает к имени, показывается под именем сервера, а не внутри него.

English: ready for 3x-ui 3.10. MASQUE servers and the XDRIVE transport, which the core does not have yet, are named under the subscription instead of vanishing, and one XDRIVE server no longer fails a whole JSON subscription; Hysteria 2 port hopping and gecko obfuscation are read from JSON subscriptions; a host's description is shown under the server name, not inside it.

## 1.0.9

- Режим VPN на Windows сам переходит на сетевой стек gVisor, если на обычном туннель не принимает соединения. Так бывает, когда файрвол или антивирус блокирует входящие подключения (например, Portmaster делает это по умолчанию): раньше приложение показывало «Подключено», а ничего не работало. Проверка занимает доли секунды; переход запоминается и показывается на главном экране.

English: VPN mode on Windows moves to the gVisor network stack by itself when the tunnel takes no connections on the usual one, as happens behind a firewall that blocks incoming connections (Portmaster does by default).

## 1.0.8

- Подключение больше не зависит от правил маршрутизации. Раньше одна неверная запись — регулярное выражение или адрес в маршрутизации из панели, «300.1.1.1» в своих правилах, повреждённый список сайтов — не давала ядру запуститься, и подключиться было нельзя совсем. Теперь такие записи отбрасываются, остальные правила работают.
- Если ядро всё же не приняло правила, приложение подключается без них и говорит об этом на главном экране; повреждённые списки сайтов загружаются заново.

English: routing can no longer keep the app from connecting: entries the core would refuse are dropped, and if it refuses the rules anyway the connection is made without them, with a notice.

## 1.0.7

- Главный экран: вместо графика скорости — трафик за сеанс отдельно «Через VPN» и «Напрямую», с долей каждого и числом открытых соединений.
- Переподключение предлагается только когда настройка действительно изменилась. Выбор уже выбранного значения или возврат настройки назад ничего не просит.

English: the home screen shows the session's traffic split into VPN and direct instead of the speed graph; a reconnect is asked for only when a setting really changed.

## 1.0.6

- Маршрутизация из панели: правила в формате Happ, заданные в 3x-ui, приходят вместе с подпиской и применяются сами. Раздел «Маршрутизация из панели» на странице «Маршруты»; туда же можно вставить ссылку happ://routing/…
- Группы приложений: Steam, Epic, Battle.net, Discord, Chrome и Edge добавляются сразу со всеми своими процессами, список процессов разворачивается нажатием. Steam сразу стоит в списке со значением «Напрямую».
- Режим VPN теперь выбран по умолчанию для новых установок.
- Главный экран: под кнопкой подключения — график скорости за минуту и сведения о режиме, маршрутах, DNS и подписке. Строки серверов стали ниже и разделены, флаги больше не сливаются.
- Журнал: подробность выбирается прямо в журнале, и список меняется сразу.
- Панель получает настоящее название устройства и версию системы (например, «MSI H510M-A PRO», «Xiaomi 13T Pro», «Windows 11 24H2») вместо кодов модели.
- Блок «Защита от блокировок» убран из настроек: защита всегда работает в режиме «Авто».

English: routing rules pushed from the panel (Happ format); program groups in per-app routing with Steam direct out of the box; VPN mode by default; a speed graph and session facts on the home screen; a log that follows its detail level; real device names sent to the panel.

## 1.0.5

- Кнопка в шторке Android: на ней теперь тот же кот в каске, что и на значке приложения, а не одна каска.

English: the quick settings tile shows the cat from the app icon instead of a bare hard hat.

## 1.0.4

- Кнопка в шторке Android: подключение и отключение одним нажатием из панели быстрых настроек (той, что открывается свайпом сверху). Добавляется в настройках приложения, пункт «Кнопка в шторке», или вручную через «Изменить» в самой шторке.
- Флаги стран: код страны в названии сервера (NL, RU, DE-2, USA, эмодзи-флаг) показывается флагом — значком рядом с названием и фоном строки. Флаги приложение рисует само, поэтому они видны и на Windows.
- Автовыбор сервера убран: подключение всегда идёт через выбранный сервер. Если был включён автовыбор, выбранным становится самый быстрый сервер этой подписки.
- Вместе с HWID серверу подписки передаётся внешний IP-адрес устройства (заголовки X-Real-IP и X-Forwarded-For). Адрес определяется мимо VPN-туннеля, так что это адрес самого устройства, а не VPN-сервера. Отключается тем же переключателем «Отправлять HWID в панель».
- Новый значок приложения.

English: a quick settings tile on Android; country flags from the codes in server names; auto-select is gone; the device's public IP address is sent to the subscription server along with the HWID; a new app icon.

## 1.0.3

- Подключение можно отменить: пока оно устанавливается, кнопка питания и ссылка «Отменить подключение» останавливают его сразу.
- Исправлено: при подробности журнала «только ошибки» рабочее подключение обрывалось через 25 секунд. Готовность ядра больше не определяется по строке в журнале.
- Режим VPN: приложение само просит права администратора при запуске, а не при первом подключении. Значок щита у переключателя показывает, что права есть. Повторный запуск открывает уже работающее окно, даже если оно запущено от администратора.
- DNS выбирается из списка (Google, Cloudflare, Quad9, AdGuard, DoH), внизу списка — «Указать вручную». По умолчанию для новых установок — 8.8.8.8.
- Журнал ядра сохраняется в файл: кнопка «Открыть папку с журналом» на странице журнала.

English: connecting can be cancelled; a quiet log level no longer kills a healthy connection after 25 seconds; VPN mode asks for administrator rights at launch; DNS is picked from a list (default 8.8.8.8); the core log is kept on disk.

## 1.0.2

- Подписки и «Мои серверы» сворачиваются нажатием на заголовок. Свёрнутая группа показывает число серверов и выбранный сервер.
- Пинг по TCP: время соединения с самим сервером. Замер идёт мимо VPN-туннеля, даже если он включён. Прежний замер «через сервер» выбирается в настройках; для WireGuard, Hysteria и TUIC он используется всегда.
- Подсказка у переключателя режима: в режиме «Системный прокси» игры и консольные программы идут мимо VPN, для них нужен режим VPN.

English: foldable server groups; TCP ping that bypasses the VPN tunnel (the old measurement through the server is a setting); a clearer hint about what system proxy mode does not cover.

## 1.0.1

- Android TV: управление пультом и приём подписки с телефона по QR-коду.
- Новый интерфейс: тёмная тема, анимированный фон, компактный вид, слайдер «Прокси / VPN».
- Виджет Android: подключение и переключение серверов с главного экрана.
- Подписки 3x-ui: HWID для лимита устройств, JSON-подписки, ключи AmneziaWG vpn://, объявления и интервал обновления из панели.
- При закрытии окна приложение спрашивает: отмена, закрыть полностью или свернуть в трей.
