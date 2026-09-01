#!/bin/zsh
# Строка статуса Claude Code. На stdin приходит JSON сессии, на stdout — строка.
# Один запуск python на отрисовку: строка обновляется часто, два стоили вдвое.
HERE=${0:A:h}

parts=$(python3 -c '
import json, os, sys
d = json.load(sys.stdin)
print(os.path.basename(d.get("workspace", {}).get("current_dir", "")))
print(d.get("model", {}).get("display_name", ""))
' 2>/dev/null)

dir=${parts%%$'\n'*}
model=${parts##*$'\n'}
tg=$("$HERE/tg-status.sh" 2>/dev/null)

out=$dir
[[ -n $model ]] && out+=" · $model"
[[ -n $tg ]] && out+=" · $tg"
print -n "$out"
