# История версий

Раздел версии публикуется как описание релиза и показывается в приложении
в блоке «Что нового», поэтому здесь простой текст без оформления.

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
