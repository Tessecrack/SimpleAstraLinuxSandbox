# SimpleAstraLinuxSandbox

Скрипт `run-astra-sandbox.sh` запускает изолированную графическую сессию Astra Linux (Fly Desktop) в отдельном `bubblewrap`-namespace, не трогая основную систему пользователя.

## Как это работает

Для изоляции используется [`bwrap`](https://github.com/containers/bubblewrap):

- отдельные mount, PID, user, IPC, UTS и cgroup namespace;
- отдельный `$HOME` (своё дерево файлов и процессов на каждую сессию);
- `/usr`, `/bin`, `/sbin`, `/lib`, `/etc`, `/var` хоста подключаются `read-only`;
- сеть — общая с хостом.

Графика рисуется через [Xephyr](https://www.freedesktop.org/wiki/Software/Xephyr/) — вложенный X-сервер на внутреннем `DISPLAY=:1`. Наружу из песочницы не торчит ничего, кроме одного X11-сокета (`/tmp/.X11-unix/X0`), который нужен Xephyr, чтобы вывести своё окно на хостовый экран. Внутри поднимаются `fly-wm`, `fly-start-panel` и `fly-term`.

## Требования

- Bash, `bwrap` (bubblewrap)
- Astra Linux / Fly Desktop (`Xephyr`, `fly-wm`, `fly-start-panel`, `fly-term`, `dbus-launch`) — всё должно быть установлено на хосте, так как системные бинарники монтируются с хоста
- `pgrep`

## Использование

```bash
./run-astra-sandbox.sh start [имя] [geometry]   # запуск сессии
./run-astra-sandbox.sh stop  [имя]              # остановка сессии
./run-astra-sandbox.sh list                     # список сессий и их статус
```

- `имя` — идентификатор сессии. Если не указан, создаётся одноразовый профиль с именем вида `tmp-<timestamp>-<pid>`, который автоматически удаляется при остановке.
- `geometry` — разрешение окна Xephyr, по умолчанию `1280x800`.

### Примеры

```bash
# Одноразовая сессия (профиль удалится после stop)
./run-astra-sandbox.sh start

# Именованная сессия с заданным разрешением
./run-astra-sandbox.sh start work 1920x1080
./run-astra-sandbox.sh stop work

# Посмотреть список всех сессий
./run-astra-sandbox.sh list
```

## Хранение данных

Состояние сессий хранится в `.astra-sandbox/<имя>/` рядом со скриптом:

- `home/` — домашняя директория песочницы (`/home/<текущий пользователь>` внутри namespace, имя берётся из `id -un` на хосте);
- `session.log` — лог запуска и работы сессии;
- `init.pid` — PID внутреннего init-процесса (корня namespace), используется для остановки;
- `ephemeral` — маркер одноразового профиля, при наличии которого каталог сессии удаляется после `stop`.

Для именованных сессий (с явно указанным `имя`) каталог `home/` сохраняется между запусками, т.е. профиль персистентный.

## Остановка

`stop` присылает `kill -9` внутреннему init-процессу namespace — ядро автоматически уничтожает весь namespace целиком (все дочерние процессы, mount-точки и т.д.).
