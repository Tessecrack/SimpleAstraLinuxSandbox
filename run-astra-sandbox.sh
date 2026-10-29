#!/usr/bin/env bash

#   ./astra-sandbox.sh start [имя]     # запуск; без имени — одноразовый профиль
#   ./astra-sandbox.sh stop  [имя]
#   ./astra-sandbox.sh list
# Изолированная графическая сессия (Fly Desktop в Xephyr) внутри namespace-песочницы
# bubblewrap: отдельные mount/PID/user/IPC/UTS/cgroup namespaces, свой $HOME,
# своё дерево процессов. Ядро и системные бинарники — общие с хостом (read-only),
# Сеть — общая с хостом.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
STATE_ROOT="$SCRIPT_DIR/.astra-sandbox"
mkdir -p "$STATE_ROOT"

CMD="${1:-start}"
NAME="${2:-}"
GEOMETRY="${3:-1280x800}"

EPHEMERAL=0
if [[ -z "$NAME" ]]; then
  NAME="tmp-$(date +%s)-$$"
  EPHEMERAL=1
fi

SANDBOX_USER="$(id -un)"
SANDBOX_HOME_DIR="/home/$SANDBOX_USER"

INSTANCE_DIR="$STATE_ROOT/$NAME"
SANDBOX_HOME="$INSTANCE_DIR/home"
LOG_FILE="$INSTANCE_DIR/session.log"
PID_FILE="$INSTANCE_DIR/init.pid"
MARK_FILE="$INSTANCE_DIR/ephemeral"

is_running() {
  [[ -f "$PID_FILE" ]] && kill -0 "$(cat "$PID_FILE")" 2>/dev/null
}

start() {
  if is_running; then
    echo "Сессия '$NAME' уже запущена (init PID $(cat "$PID_FILE"))." >&2
    exit 1
  fi
  rm -f "$PID_FILE"
  mkdir -p "$SANDBOX_HOME"
  [[ "$EPHEMERAL" == 1 ]] && touch "$MARK_FILE"

  echo "Запускаю изолированную сессию Astra '$NAME' ($GEOMETRY)..."

  # Внутренний display :1 существует только в приватном /tmp песочницы —
  # наружу (на хост) не торчит вообще ничего, кроме единственного сокета
  # X0, который нужен Xephyr, чтобы нарисовать своё окно на хостовом экране.
  nohup bwrap \
    --unshare-user --unshare-pid --unshare-ipc --unshare-uts --unshare-cgroup-try \
    --hostname astra-sandbox \
    --proc /proc \
    --dev /dev \
    --ro-bind /usr /usr \
    --ro-bind /bin /bin \
    --ro-bind /sbin /sbin \
    --ro-bind /lib /lib \
    --ro-bind-try /lib64 /lib64 \
    --ro-bind /etc /etc \
    --ro-bind /var /var \
    --bind "$SANDBOX_HOME" "$SANDBOX_HOME_DIR" \
    --tmpfs /tmp \
    --ro-bind-try /tmp/.X11-unix/X0 /tmp/.X11-unix/X0 \
    --tmpfs /run \
    --dir /run/user/1000 \
    --chmod 0700 /run/user/1000 \
    --setenv HOME "$SANDBOX_HOME_DIR" \
    --setenv USER "$SANDBOX_USER" \
    --setenv XDG_RUNTIME_DIR /run/user/1000 \
    --chdir "$SANDBOX_HOME_DIR" \
    -- bash -c '
      Xephyr :1 -screen "'"$GEOMETRY"'" -resizeable -title "Astra Sandbox" &
      XPID=$!
      for i in $(seq 1 50); do
        [ -S /tmp/.X11-unix/X1 ] && break
        sleep 0.1
      done
      export DISPLAY=:1
      dbus-launch --exit-with-session fly-wm --display :1 &
      sleep 1
      fly-start-panel &
      fly-term &
      wait "$XPID"
    ' > "$LOG_FILE" 2>&1 < /dev/null &

  OUTER_PID=$!
  disown

  # дождаться, пока появится внутренний init-процесс (дочерний от OUTER_PID) —
  # именно его PID нужно убивать при остановке, чтобы ядро снесло весь namespace
  INIT_PID=""
  for i in $(seq 1 50); do
    INIT_PID=$(pgrep -P "$OUTER_PID" | head -1 || true)
    [[ -n "$INIT_PID" ]] && break
    sleep 0.1
  done

  if [[ -z "$INIT_PID" ]] || ! kill -0 "$INIT_PID" 2>/dev/null; then
    echo "Не удалось запустить сессию, смотрите лог: $LOG_FILE" >&2
    cat "$LOG_FILE" >&2
    exit 1
  fi

  echo "$INIT_PID" > "$PID_FILE"
  sleep 1

  if kill -0 "$INIT_PID" 2>/dev/null; then
    echo "Готово. Сессия '$NAME' запущена."
    echo "Лог: $LOG_FILE"
    echo "Остановить: $0 stop $NAME"
  else
    echo "Сессия завершилась сразу после запуска, смотрите лог: $LOG_FILE" >&2
    cat "$LOG_FILE" >&2
    exit 1
  fi
}

stop() {
  if ! is_running; then
    echo "Сессия '$NAME' не запущена."
  else
    INIT_PID=$(cat "$PID_FILE")
    kill -9 "$INIT_PID" 2>/dev/null || true
    echo "Сессия '$NAME' остановлена (весь namespace снесён ядром)."
  fi
  rm -f "$PID_FILE"
  if [[ -f "$MARK_FILE" ]]; then
    rm -rf "$INSTANCE_DIR"
    echo "Одноразовый профиль удалён."
  fi
}

list() {
  shopt -s nullglob
  for d in "$STATE_ROOT"/*/; do
    n="$(basename "$d")"
    if [[ -f "$d/init.pid" ]] && kill -0 "$(cat "$d/init.pid")" 2>/dev/null; then
      echo "$n  [запущена, PID $(cat "$d/init.pid")]"
    else
      echo "$n  [остановлена]"
    fi
  done
}

case "$CMD" in
  start) start ;;
  stop) stop ;;
  list) list ;;
  *) echo "Использование: $0 {start|stop|list} [имя] [geometry]" >&2; exit 1 ;;
esac
