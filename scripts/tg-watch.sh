#!/bin/zsh
# Периодический сторож Telegram-поллера — запускается по таймеру (launchd),
# а не изнутри сессии Claude, как остальные скрипты этого плагина.
#
# Важное ограничение, о котором нужно знать сразу: этот скрипт ловит только
# то, что видно СНАРУЖИ процесса — поллер (bun server.ts) не запущен, их
# несколько (конфликт), завис на высоком CPU. Тот случай, когда поллер жив
# и здоров, а MCP-мост к конкретной сессии Claude тихо отвалился, — снаружи
# НЕ виден. Проверено: у Claude Code нет для этого ни лога, ни хука, ни API.
# Здесь это не чинится — по-честному, чинить нечем.
#
# Что реально даёт сторож: те же проверки, что и /tg-fix, но по таймеру,
# без необходимости вспомнить и зайти проверить руками — и алерт уходит
# через ВТОРОЙ, независимый канал/бот, чтобы отказ основного канала не
# оставил человека без уведомления о себе самом.
#
# Никаких автоматических «лечений» скрипт не делает: убить/перезапустить
# поллер снаружи бессмысленно (он живёт как подпроцесс конкретной сессии
# Claude, новый процесс ни к чему не подключится), а перезапускать саму
# интерактивную сессию человека из таймера без спроса — риск оборвать
# работу без предупреждения. Решение остаётся за человеком, сторож только
# зовёт на помощь.
#
# Настройка — через ~/.claude/tg-watch.env (создаётся командой /tg-watch-setup):
#   TELEGRAM_STATE_DIR      — какой канал мониторим (по умолчанию ~/.claude/channels/telegram)
#   TG_WATCH_ALERT_DIR      — состояние ВТОРОГО канала, откуда шлём алерт (обязательно)
#   TG_WATCH_ALERT_CHAT_ID  — кому слать алерт (обязательно)

set -u

CONFIG_FILE="$HOME/.claude/tg-watch.env"
[[ -r "$CONFIG_FILE" ]] && source "$CONFIG_FILE"

MAIN_DIR="${TELEGRAM_STATE_DIR:-$HOME/.claude/channels/telegram}"
ALERT_DIR="${TG_WATCH_ALERT_DIR:-}"
ALERT_CHAT_ID="${TG_WATCH_ALERT_CHAT_ID:-}"
STATE_FILE="$HOME/.claude/.tg-watch-state"
RECHECK_COOLDOWN=$((60 * 60))  # не долбить одним и тем же алертом чаще раза в час

log() { print -- "$(date '+%Y-%m-%d %H:%M:%S') $*"; }

if [[ -z "$ALERT_DIR" || -z "$ALERT_CHAT_ID" ]]; then
  log "не настроено — запусти /tg-watch-setup (нужны TG_WATCH_ALERT_DIR и TG_WATCH_ALERT_CHAT_ID в $CONFIG_FILE)"
  exit 1
fi

# ---- health-check основного канала (логика как в tg-status.sh) ----

pids=(${(f)"$(pgrep -f 'bun server\.ts' 2>/dev/null)"})
main_pids=()
for p in $pids; do
  dir=$(ps eww -p $p 2>/dev/null | tr ' ' '\n' | grep -m1 '^TELEGRAM_STATE_DIR=' | cut -d= -f2-)
  [[ "${dir:-$HOME/.claude/channels/telegram}" == "$MAIN_DIR" ]] && main_pids+=($p)
done

n=${#main_pids[@]}
tg_state="ok"
detail=""

if (( n == 0 )); then
  tg_state="down"
  detail="поллер не запущен (0 процессов)"
elif (( n > 1 )); then
  tg_state="conflict"
  detail="${n} инстанса поллера одновременно — конфликт long polling"
else
  bot=${main_pids[1]}
  cpu=$(ps -o %cpu= -p $bot 2>/dev/null | tr -d ' ' | cut -d. -f1)
  if (( ${cpu:-0} > 50 )); then
    tg_state="hung"
    detail="процесс завис (${cpu}% CPU)"
  fi
fi

# ---- дебаунс: не слать один и тот же алерт чаще RECHECK_COOLDOWN ----

now=$(date +%s)
prev_status=""
prev_ts=0
if [[ -r "$STATE_FILE" ]]; then
  prev_status=$(sed -n '1p' "$STATE_FILE")
  prev_ts=$(sed -n '2p' "$STATE_FILE")
fi

if [[ "$tg_state" == "ok" ]]; then
  log "ok"
  print -- "ok\n$now" > "$STATE_FILE"
  exit 0
fi

log "problem: $tg_state — $detail"

should_alert=1
if [[ "$tg_state" == "$prev_status" ]] && (( now - ${prev_ts:-0} < RECHECK_COOLDOWN )); then
  should_alert=0
fi

print -- "$tg_state\n$now" > "$STATE_FILE"

(( should_alert == 0 )) && { log "уже алертили недавно про тот же статус — молчу"; exit 0 }

# ---- алерт через ВТОРОЙ, независимый бот ----

if [[ ! -r "$ALERT_DIR/.env" ]]; then
  log "нет $ALERT_DIR/.env — алерт слать некуда"
  exit 1
fi

TOKEN=$(grep -m1 '^TELEGRAM_BOT_TOKEN=' "$ALERT_DIR/.env" | cut -d= -f2-)
if [[ -z "$TOKEN" ]]; then
  log "TELEGRAM_BOT_TOKEN пустой в $ALERT_DIR/.env"
  exit 1
fi

TEXT="⚠️ tg-watch: основной канал Telegram — проблема.
$detail
Проверь: /tg-fix в терминале с этой сессией, либо /mcp → reconnect telegram."

curl -s -X POST "https://api.telegram.org/bot${TOKEN}/sendMessage" \
  -H "Content-Type: application/json" \
  -d "$(python3 -c 'import json,sys; print(json.dumps({"chat_id": sys.argv[1], "text": sys.argv[2]}))' "$ALERT_CHAT_ID" "$TEXT")" \
  > /dev/null

log "алерт отправлен"
