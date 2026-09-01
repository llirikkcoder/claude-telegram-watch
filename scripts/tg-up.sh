#!/bin/zsh
# Приводит Telegram-канал в рабочее состояние за один вызов.
#
# Зачем отдельная команда, если есть /tgbot и /tg-fix: те показывают состояние
# и чинят конфликт двух поллеров, но когда бота нет вообще, оба заканчиваются
# фразой «поднимется сам при следующем старте сессии» — и человек остаётся
# гадать, что нажать. Здесь весь путь пройден до конца: мусор убран, токен
# проверен, и напечатано ровно одно действие.
#
# Чего эта команда принципиально не может: поднять бота сама. server.ts —
# MCP-сервер на stdio, он разговаривает с Claude Code через трубу. Запущенный
# из скрипта, он окажется без собеседника: процесс живой, апдейты приходят,
# отдать их некому. Поэтому поднять канал может только сам Claude Code —
# через /mcp или перезапуск сессии.

set -u

STATE_DIR=${TELEGRAM_STATE_DIR:-~/.claude/channels/telegram}
PIDFILE=$STATE_DIR/bot.pid
ENVFILE=$STATE_DIR/.env

print "── Telegram-канал ───────────────────────────────"
print ""

# ── 1. Убираем лишние экземпляры ────────────────────────────────
# Делает то же, что /tg-fix, но молча и только когда есть что делать:
# отдельный вызов ради «всё в порядке» — лишний шаг в и без того долгом пути.
pids=(${(f)"$(pgrep -f 'bun server\.ts' 2>/dev/null)"})
n=${#pids[@]}

if (( n > 1 )); then
  print "Экземпляров: $n — это конфликт: Telegram отдаёт апдейты одному."
  ~/.claude/bin/tg-fix.sh | sed 's/^/  /'
  print ""
  pids=(${(f)"$(pgrep -f 'bun server\.ts' 2>/dev/null)"})
  n=${#pids[@]}
fi

# Зависший экземпляр крутит переподключение на полном ядре и апдейты уже не
# забирает. Живой поллер почти всё время спит в ожидании ответа Telegram.
if (( n == 1 )); then
  bot=${pids[1]}
  cpu=$(ps -o %cpu= -p $bot 2>/dev/null | tr -d ' ' | cut -d. -f1)
  if (( ${cpu:-0} > 50 )); then
    print "Экземпляр pid $bot завис (${cpu}% CPU) — снимаю."
    kill $bot 2>/dev/null && sleep 1
    kill -0 $bot 2>/dev/null && kill -9 $bot 2>/dev/null
    n=0
  fi
fi

# ── 2. Проверяем токен ──────────────────────────────────────────
# Дохлый токен выглядит как «бот не отвечает», и без этой проверки человек
# идёт перезапускать сессию по кругу, хотя перезапуск ничего не изменит.
token=""
[[ -r $ENVFILE ]] && token=$(grep -m1 '^TELEGRAM_BOT_TOKEN=' $ENVFILE 2>/dev/null | cut -d= -f2-)

if [[ -z $token ]]; then
  print "✗ Токен не найден: $ENVFILE"
  print ""
  print "Без токена канал не поднимется. Проверьте файл."
  exit 1
fi

me=$(curl -s --max-time 10 "https://api.telegram.org/bot${token}/getMe" 2>/dev/null)
if [[ $me != *'"ok":true'* ]]; then
  print "✗ Telegram не принимает токен."
  print "  Ответ: $(print -- $me | head -c 120)"
  print ""
  print "Перезапуск сессии не поможет — нужен рабочий токен в $ENVFILE."
  exit 1
fi

botname=$(print -- $me | sed -n 's/.*"username":"\([^"]*\)".*/\1/p')
print "Бот @${botname}: токен принят Telegram."

# ── 3. Определяем, кому принадлежит канал ───────────────────────
claude_session_of() {
  local p=$1 cmd
  while [[ -n $p && $p != 1 ]]; do
    cmd=$(ps -o command= -p $p 2>/dev/null)
    [[ $cmd == claude* ]] && { print -- $p; return 0 }
    p=$(ps -o ppid= -p $p 2>/dev/null | tr -d ' ')
  done
  return 1
}

if (( n == 1 )); then
  bot=${pids[1]}
  mine=$(claude_session_of $$)
  owner=$(claude_session_of $bot)

  if [[ -n $mine && -n $owner && $mine == $owner ]]; then
    print "Канал работает в этом окне (pid $bot). Делать нечего."
    exit 0
  fi

  print ""
  print "Канал занят другим окном Claude (pid $bot)."
  print ""
  print "Забрать его сюда:"
  print "  ~/.claude/bin/tg-set.sh --take"
  print ""
  print "После этого — шаг 4 ниже: сам он сюда не переедет."
  print "Осторожно: в том окне канал замолчит."
  exit 0
fi

# ── 4. Бота нет — печатаем единственное действие ────────────────
print ""
print "Экземпляр не запущен."
print ""
print "Поднять его может только Claude Code — server.ts общается с ним"
print "через трубу, запущенный вручную он останется без собеседника."
print ""
print "  1. /mcp"
print "  2. выбрать telegram → reconnect"
print ""
print "Если telegram в списке нет, сессия стартовала без канала:"
print "  claude --channels plugin:telegram@claude-plugins-official"
