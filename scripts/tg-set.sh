#!/bin/zsh
# Кто держит Telegram-канал и как забрать его себе.
#
# Канал принадлежит той сессии Claude, которая подняла экземпляр бота:
# long polling Telegram отдаёт апдейты одному клиенту, и это он. Соседнее
# окно при этом молчит, сколько его ни перезапускай.
#
# Без аргументов — показывает владельца так, чтобы его можно было найти
# среди десятков открытых окон: терминал, рабочий каталог, время запуска.
# С --take — снимает чужой экземпляр, освобождая канал для текущей сессии.

set -u

TAKE=0
[[ "${1:-}" == "--take" ]] && TAKE=1

# Поднимаемся по цепочке процессов до ближайшей сессии Claude.
claude_session_of() {
  local p=$1 cmd
  while [[ -n $p && $p != 1 ]]; do
    cmd=$(ps -o command= -p $p 2>/dev/null)
    [[ $cmd == claude* ]] && { print -- $p; return 0 }
    p=$(ps -o ppid= -p $p 2>/dev/null | tr -d ' ')
  done
  return 1
}

describe_session() {
  local s=$1
  local tty=$(ps -o tty= -p $s 2>/dev/null | tr -d ' ')
  local started=$(ps -o lstart= -p $s 2>/dev/null | sed 's/^ *//')
  local cwd=$(lsof -a -p $s -d cwd -Fn 2>/dev/null | grep '^n' | sed 's/^n//' | head -1)
  print "  сессия claude $s"
  [[ -n $tty ]] && print "  терминал:  $tty"
  [[ -n $cwd ]] && print "  каталог:   $cwd"
  [[ -n $started ]] && print "  запущена:  $started"
}

mine=$(claude_session_of $$)
pids=(${(f)"$(pgrep -f 'bun server\.ts' 2>/dev/null)"})

if (( ${#pids[@]} == 0 )); then
  print "Канал сейчас никем не занят: ни одного экземпляра бота."
  print ""
  print "Сам он не поднимется: экземпляр запускает MCP-клиент сессии при"
  print "подключении. Чтобы канал заработал здесь — /mcp и переподключить"
  print "telegram, либо перезапустить сессию."
  print ""
  print "Если сессия запущена вообще без канала, нужен ключ:"
  print "  claude --channels plugin:telegram@claude-plugins-official"
  exit 0
fi

print "Экземпляров бота: ${#pids[@]}"
print ""

owners=()
for b in $pids; do
  o=$(claude_session_of $b)
  owners+=(${o:-0})
  if [[ -n $o && $o == $mine ]]; then
    print "Канал держит ЭТА сессия (бот $b) — сообщения приходят сюда."
  elif [[ -n $o && $o != 0 ]]; then
    print "Канал держит ДРУГАЯ сессия (бот $b):"
    describe_session $o
  else
    print "Бот $b осиротел — окно, поднявшее его, закрыто."
  fi
  print ""
done

if (( ! TAKE )); then
  if [[ ${owners[(I)$mine]} -gt 0 ]]; then
    print "Забирать нечего: канал уже здесь."
  else
    print "Чтобы забрать канал себе:  tg-set.sh --take"
    print "В том окне канал после этого замолчит до его перезапуска."
  fi
  exit 0
fi

# --take: снимаем всё, что принадлежит не нам.
killed=0
for i in {1..${#pids[@]}}; do
  b=${pids[$i]}
  o=${owners[$i]}
  [[ $o == $mine ]] && continue

  ppid=$(ps -o ppid= -p $b 2>/dev/null | tr -d ' ')
  kill $b 2>/dev/null
  sleep 1
  kill -0 $b 2>/dev/null && kill -9 $b 2>/dev/null
  # Обёртка bun run иначе останется висеть сиротой.
  if [[ -n ${ppid:-} && $ppid != 1 ]]; then
    ps -o command= -p $ppid 2>/dev/null | grep -q 'bun run' && kill $ppid 2>/dev/null
  fi
  killed=$((killed + 1))
  print "Снят чужой экземпляр (бот $b, сессия ${o:-сирота})"
done

if (( killed == 0 )); then
  print "Ничего снимать не пришлось — канал и так здесь."
  exit 0
fi

print ""
print "Канал освобождён — но сам он сюда не переедет."
print ""
print "Экземпляр бота поднимает MCP-клиент сессии при подключении, а не"
print "команда извне. Проверено: после снятия чужого процесса новый не"
print "появляется ни через минуту, ни позже. Дальше — одно из двух:"
print ""
print "  • в Claude Code выполнить /mcp и переподключить telegram;"
print "  • либо перезапустить эту сессию."
print ""
print "После этого:  tg-status.sh  покажет tg ✓"
