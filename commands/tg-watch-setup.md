---
description: Поставить фоновый сторож — алерт, если Telegram-поллер реально упал
allowed-tools: Bash, Read, Write
---

Этот плагин обычно чинит проблемы изнутри живой сессии (`/tg-fix`, `/tgbot`). Этот скрипт — другое: фоновая задача launchd, которая проверяет канал раз в 5 минут САМА ПО СЕБЕ, даже когда никто не работает в терминале, и присылает алерт, если поллер реально упал.

**Сначала скажи человеку то, что он должен знать до установки** — не проси "ок", просто изложи и переходи к шагам:

Сторож ловит только то, что видно снаружи процесса: поллер не запущен, конфликт нескольких инстансов, завис на CPU. Тот случай, когда поллер жив, а MCP-мост к сессии Claude тихо отвалился, — сторож НЕ видит и не может увидеть: у Claude Code нет для этого способа наблюдения снаружи. Автоматически ничего не чинит — только шлёт алерт с рекомендацией сделать `/mcp` reconnect или перезапустить сессию.

Для алерта нужен ВТОРОЙ, независимый Telegram-канал/бот — если алерт слать через тот же канал, что мониторим, при падении алерт тоже не дойдёт.

### Шаги

1. Найди основной канал для мониторинга — по умолчанию `~/.claude/channels/telegram`. Если у человека нестандартный `TELEGRAM_STATE_DIR`, уточни.

2. Найди кандидатов на роль второго канала:
!`ls -d ~/.claude/channels/*/ 2>/dev/null`

   Если каналов больше одного — спроси человека, какой из них использовать для алертов (не основной). Если второго канала нет вообще — скажи прямо: без него сторож ставить бессмысленно (алерт некому будет слать при падении основного), и остановись — не создавай второй канал сам.

3. Определи, кому слать алерт. Разумный дефолт — первая запись `allowFrom` из access.json основного канала:
!`cat ~/.claude/channels/telegram/access.json 2>/dev/null`

   Покажи найденный chat_id человеку и спроси, тот ли это адресат, прежде чем писать конфиг.

4. Запиши конфиг `~/.claude/tg-watch.env` (создай, не спрашивая — это просто локальный файл настроек, не более того):
   ```
   TELEGRAM_STATE_DIR=<основной канал>
   TG_WATCH_ALERT_DIR=<путь ко второму каналу>
   TG_WATCH_ALERT_CHAT_ID=<chat_id>
   ```

5. Сгенерируй launchd plist по адресу `~/Library/LaunchAgents/com.claude.tg-watch.plist`, подставив реальный путь к скрипту (`${CLAUDE_PLUGIN_ROOT}/scripts/tg-watch.sh` — резолвь переменную в конкретный путь, launchd её не понимает):
   ```xml
   <?xml version="1.0" encoding="UTF-8"?>
   <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
   <plist version="1.0">
   <dict>
     <key>Label</key>
     <string>com.claude.tg-watch</string>
     <key>ProgramArguments</key>
     <array>
       <string>/bin/zsh</string>
       <string>ПОДСТАВЬ_АБСОЛЮТНЫЙ_ПУТЬ/scripts/tg-watch.sh</string>
     </array>
     <key>StartInterval</key>
     <integer>300</integer>
     <key>RunAtLoad</key>
     <false/>
     <key>StandardOutPath</key>
     <string>~/.claude/.tg-watch.log</string>
     <key>StandardErrorPath</key>
     <string>~/.claude/.tg-watch.log</string>
   </dict>
   </plist>
   ```

6. Спроси явное подтверждение перед активацией — запуск фоновой задачи, которая будет действовать сама по себе без присмотра, это не мелочь. Только после "да":
   ```
   launchctl unload ~/Library/LaunchAgents/com.claude.tg-watch.plist 2>/dev/null
   launchctl load ~/Library/LaunchAgents/com.claude.tg-watch.plist
   launchctl list | grep tg-watch
   ```

7. Доложи итог: что настроено (какие два канала, кому шлём), что сторож умеет и чего не умеет — повтори ограничение из начала коротко, это не разовая оговорка для галочки.

### Как проверить, что работает

`${CLAUDE_PLUGIN_ROOT}/scripts/tg-watch.sh` можно запустить руками в любой момент — если всё штатно, тихо пишет "ok" в лог и выходит; если найдёт проблему, реально пришлёт алерт (не тестовое сообщение — настоящее, с текущим статусом).

### Чтобы снять

```
launchctl unload ~/Library/LaunchAgents/com.claude.tg-watch.plist
rm ~/Library/LaunchAgents/com.claude.tg-watch.plist
```
