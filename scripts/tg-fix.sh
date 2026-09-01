#!/bin/zsh
# Оставляет ровно один экземпляр Telegram-бота и убивает остальные.
#
# Telegram отдаёт long polling одному клиенту. Каждая сессия Claude поднимает
# свой bun server.ts, поэтому два открытых окна = два поллера на одном токене:
# сообщения достаются то одному, то другому, и человеку кажется, что бот
# «отвалился». Плюс закрытое окно оставляет процесс-сироту, который крутит
# цикл переподключения на полном ядре и апдейты уже не забирает.
#
# Кого оставляем: процесс из bot.pid — его записал тот, кто поднялся последним,
# и именно на него настроен канал. Если его нет в живых — самый свежий из
# оставшихся: он с наибольшей вероятностью привязан к открытому окну.

set -u

PIDFILE=~/.claude/channels/telegram/bot.pid
DRY=0
[[ "${1:-}" == "--dry-run" ]] && DRY=1

pids=(${(f)"$(pgrep -f 'bun server\.ts' 2>/dev/null)"})
n=${#pids[@]}

if (( n == 0 )); then
  print "Бот не запущен: ни одного экземпляра."
  print "Поднимется сам при следующем старте сессии с каналом telegram."
  exit 0
fi

if (( n == 1 )); then
  print "Всё в порядке: работает один экземпляр (pid ${pids[1]})."
  exit 0
fi

# Выбираем, кого оставить.
keep=""
if [[ -r $PIDFILE ]]; then
  saved=$(<$PIDFILE)
  for p in $pids; do
    [[ $p == $saved ]] && keep=$p && break
  done
fi

if [[ -z $keep ]]; then
  # bot.pid пуст или указывает на мертвеца — берём самый молодой процесс.
  keep=$(ps -o pid=,lstart= -p ${(j: :)pids} | sort -k2 | tail -1 | awk '{print $1}')
fi

print "Экземпляров: $n. Оставляю pid $keep, остальные снимаю."
print ""

for p in $pids; do
  [[ $p == $keep ]] && continue

  cpu=$(ps -o %cpu= -p $p 2>/dev/null | tr -d ' ' | cut -d. -f1)
  ppid=$(ps -o ppid= -p $p 2>/dev/null | tr -d ' ')
  why="лишний поллер"
  [[ ${ppid:-0} == 1 ]] && why="сирота от закрытого окна"
  (( ${cpu:-0} > 50 )) && why="завис (${cpu}% CPU)"

  if (( DRY )); then
    print "  [проверка] снял бы pid $p — $why"
    continue
  fi

  kill $p 2>/dev/null
  # Зависший в цикле переподключения до обработчика сигнала не доходит.
  sleep 1
  if kill -0 $p 2>/dev/null; then
    kill -9 $p 2>/dev/null
    print "  снят pid $p — $why (потребовался kill -9)"
  else
    print "  снят pid $p — $why"
  fi

  # Обёртка bun run остаётся сиротой и висит без дела.
  if [[ -n ${ppid:-} && ${ppid} != 1 ]]; then
    if ps -o command= -p $ppid 2>/dev/null | grep -q 'bun run'; then
      kill $ppid 2>/dev/null
    fi
  fi
done

(( DRY )) && { print ""; print "Это была проверка, ничего не менялось."; exit 0 }

sleep 1
left=$(pgrep -f 'bun server\.ts' 2>/dev/null | wc -l | tr -d ' ')
print ""
print "Осталось экземпляров: $left"
[[ $left == 1 ]] && print "Готово — конфликт снят, сообщения снова идут в одну сессию."
