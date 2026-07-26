# Код-ревью dadbod-grip.nvim

*26 июля 2026, коммит `c794939`. Четыре Opus-агента по зонам (view / core / adapters / misc) + ручная верификация ключевых находок. Только чтение — код не менялся.*

> **Статус: план из раздела 7 выполнен.** Ветка `refactor/code-review-2026-07`, 32 коммита поверх `c794939`, `main` не тронут. Тесты зелёные (`RESULT: ALL TESTS PASSED`), устаревших API не осталось.
> Что именно закрыто — раздел **8**. Что осталось на следующий проход — раздел **9**.
> Разделы 1-6 оставлены как есть: это протокол находок на момент ревью, а не отчёт о работе. Номера строк в них относятся к `c794939` и после рефакторинга сдвинулись — сверяйся с разделом 8.

## Общая оценка

Кодовая база в хорошей форме — заметно дисциплинированнее, чем обычно бывает у плагинов такого размера. Устаревших API почти нет (нет `nvim_buf_set_option`, `tbl_flatten`, `tbl_islist`; `vim.uv` вместо `vim.loop`), augroup-ы везде с `clear = true`, квотинг централизован в `sql.lua`, комментарии объясняют *почему*, а не *что*, чистые функции экспортированы для тестов. Настоящих подтверждённых багов немного — они перечислены первыми.

Главный долг — **структурный**: отсутствие общего слоя привело к расползанию копий. Центрированный float написан ~5 раз, JSON pretty-print — 3 раза, `project_root()` — 4 раза, определение адаптера по URL — 3 раза (и копии уже разошлись). `view.lua:_setup_keymaps` — одна функция на 3054 строки, `init.lua:setup()` — ~900 строк, включая чужую логику Query Doctor.

---

## 1. Подтверждённые баги (проверены вручную по коду)

### 1.1 Lua-фоллбэк форматтера ломает операторы PostgreSQL — `format.lua:121-130`
Ветка `->>` (строка 128) недостижима: двухсимвольная проверка `c2 == "->"` (строка 122) срабатывает раньше. Агент прогнал `M._format_lua`: `data ->> 'name'` → `data -> > 'name'`, `a @> b` → `a @ > b`, `tags && ARRAY['a']` → `tags & & ARRAY [ 'a' ]`. Срабатывает у всех без установленного `sql-formatter`/`pg_format`/`sqlfluff` — `gF` молча портит запрос.
**Фикс:** проверку трёхсимвольных (`->>`, `#>>`) поднять выше двухсимвольных; в двухсимвольный список добавить `@>`, `<@`, `&&`, `#>`, `<<`, `>>`.

### 1.2 `run_cmd` бросает исключение при отсутствии CLI-бинаря — `adapters/init.lua:22`
`vim.system` кидает `error()` на ENOENT, а `pcall`-а нет. Заголовки адаптеров обещают «never throw», но проверку `executable()` делают только `query`/`execute`/`ping`. Пример: `schema.lua → db.list_tables → psql` без установленного psql даёт Lua-traceback вместо notify.
**Фикс:** `pcall` вокруг `vim.system` внутри `run_cmd`, возврат `("", tostring(err), 1)` — все вызывающие уже обрабатывают `code ~= 0`.

### 1.3 DuckDB ATTACH не экранирует DSN — `duckdb.lua:51`
`string.format("ATTACH IF NOT EXISTS '%s' AS %s;", a.dsn, a.alias)` — без `:gsub("'", "''")`, хотя валидационный путь того же ATTACH (`duckdb.lua:794`) экранирует. DSN приходит из `:GripAttach` и персистится — одна кавычка ломает все последующие запросы соединения.
**Фикс:** одна строка — привести к виду строки 794.

### 1.4 `vim.cmd("GripExplain " .. sql)` ломается на многострочном SQL — `view.lua:1914`, `view.lua:4642`
`vim.cmd` делит аргумент по переводам строк и выполняет каждую как команду; SQL из query pad многострочный.
**Фикс:** звать `vim.cmd("GripExplain")` без аргумента — `init.lua:1829-1836` сам резолвит SQL из сессии той же логикой.

### 1.5 `ga` агрегирует устаревшее визуальное выделение — `view.lua:4354-4361`
`grid_aggregate` замаплен только в normal mode, но читает `'<`/`'>` — метки *предыдущего* выделения. После любого визуального выделения ранее `ga` тихо агрегирует старый диапазон вместо всей колонки.
**Фикс:** в normal-маппинге всегда брать полный диапазон; для выделения — отдельный visual-маппинг с `get_visual_rows()`.

### 1.6 `DROP TABLE ... CASCADE` — синтаксическая ошибка в SQLite — `ddl.lua:258-260`
Проверено: `sqlite3 ":memory:" "DROP TABLE t CASCADE"` → syntax error. В MySQL слово парсится, но игнорируется (ложное ощущение каскада). Фикс меняет генерируемый SQL — **требует твоего решения**, не «безопасная» правка.

### 1.7 Мелкие подтверждённые дефекты
- `view.lua:5060` — `s.state.total_rows` никогда не задаётся (везде `session.total_rows`), метка `[N rows]` в `gJ` всегда пустая.
- `view.lua:756` — хайлайт-группа `GripColType` нигде не определена, буллет фильтра не подсвечивается.
- `sqlserver.lua:60,153` — `SET NOCOUNT ON` подавляет `(N rows affected)`, который `execute` затем парсит → всегда `affected = 0`.
- `init.lua:885-887` — refresh после DDL обновляет *произвольный* грид (`pairs` + `break`), а не активный.
- `query_pad.lua:125-128` — единственный `vim.schedule` в кодовой базе без проверки `nvim_buf_is_valid`; после wipe пада бросит «Invalid buffer id».
- `ai.lua:274-290` — при `#mentioned > 30` граница цикла отрицательная, лимит в 30 таблиц обходится.

---

## 2. Производительность

### 2.1 Кубический рендер сетки: `effective_value` — `data.lua:278-279` + `view.lua:473,625,661` ⭐ самый жирный выигрыш
`effective_value` перестраивает карту `col_idx` на **каждый вызов**, а `view.lua` зовёт её трижды на ячейку (ширины, строки, хайлайты). Сетка 100×40 → ~480 000 вставок в таблицу за перерисовку; 1000×20 → ~1.2 млн. Итог `O(rows × cols²) × 3`.
**Фикс (два независимых):** мемоизировать `col_idx` по `state.columns` (комментарий в `data.lua:46-52` фиксирует, что columns не мутируется); в `view.lua` переиспользовать уже вычисленный `display_rows[di][i]` вместо повторных вызовов. Вместе — честный `O(rows × cols)`.

### 2.2 Подсветка колонки перестраивает extmark каждой строки на каждый ход курсора — `view.lua:5178-5225`
`CursorMoved` чистит namespace и ставит ~1001 extmark на страницу в 1000 строк даже при `j`/`k`, когда колонка не изменилась.
**Фикс:** мемо последней подсвеченной колонки на `session._render` (рендер создаёт свежий `_render` → кэш инвалидируется сам) + ранний `return`.

### 2.3 Сэмплирование ширин сведено на нет — `view.lua:469-481`
`calc_col_widths` сэмплирует 100+10 строк, но вызывающий сперва материализует `display_rows` для **всех** строк, а единственный потребитель — сам `calc_col_widths`. На 10 000 строк ~9 890 материализованы впустую.

### 2.4 N+1 спавнов CLI
- `view.lua:1698-1718` (`fetch_view_fk`, клавиша `7`) — запрос на каждую таблицу схемы, хотя `db.get_referencing_foreign_keys` (`db.lua:263`) делает это одним запросом и уже используется в `_fk_referencing`.
- `ddl.lua:242-256` (`drop_table`) — тот же паттерн, тот же готовый API.
- `ai.lua:294-302` — до 90 синхронных спавнов (3 × 30 таблиц), хотя `db.get_schema_batch` реализован у всех пяти адаптеров.
- `sqlite.lua:293` (`get_indexes`) — процесс на индекс; сворачивается в один JOIN через `pragma_index_info`.

### 2.5 Прочее
- `db.lua:73-80` (`parse_csv`) — посимвольная сборка quoted-полей: O(n²) на больших blob-ах + аллокация строки на каждый байт (`raw:sub(i,i)`). Лечится `raw:find('"', i, true)` + `table.concat` и `raw:byte(i)`.
- `completion.lua:472-514` — на каждый ввод символа конкатенация всего буфера + 4 прохода `gmatch`; кэш по `b:changedtick`. Плюс `warm_schema` — no-op для всех, кроме DuckDB (async-вариант есть только там), так что холодный кэш = блокирующий спавн CLI посреди набора.
- `connections.lua:517-545` (`switch`) — 4 чтения + 2 записи одного файла за одно переключение; `history.lua:69-109` — полная перезапись файла истории на каждый запрос (JSONL позволяет append).
- `grip_picker.lua` — `filtered_items()` трижды за рендер; `view.lua:183-189` — per-символьные `vim.fn`-вызовы в `truncate_display`, ASCII fast-path снял бы почти всё.

---

## 3. Переиспользование (главные кандидаты)

| Что дублируется | Где | Куда вынести |
|---|---|---|
| Центрированный info-float | `view.lua:1564`, `properties.lua:216`, `json_tree.lua:245`, `er_diagram.lua:522`, `editor.lua:292` | `ui.info_float()` |
| JSON pretty-print (поведение уже разошлось: `view` не эскейпит `\n`/`\t`, `cell_buffer` корректен) | `view.lua:1349`, `cell_buffer.lua:43`, `json_tree.lua:120` | оставить `cell_buffer.pretty_lines` |
| `project_root()` / `ensure_dir()` | `history.lua`, `saved.lua`, `filters.lua`, `connections.lua` | модуль `paths.lua` |
| Экранирование литералов `:gsub("'", "''")` — 37 инлайнов | все 5 адаптеров | `sql.escape_literal()` |
| `split_table_name` — 3 копии + 7 инлайнов в sqlite | postgresql, mysql, sqlserver, sqlite | `sql.split_table_name()` |
| `parse_url` (dadbod-URL) | `mysql.lua:26`, `sqlserver.lua:11` | `sql.parse_dadbod_url(url, port)` |
| `mysql_exec` — побайтовая копия `mysql_query` | `mysql.lua:115-141` | удалить, звать `mysql_query` |
| Экспорт (CSV/JSON/INSERT/Markdown) — 3 копии, уже дрейфуют (`tostring` есть/нет) | `view.lua:1440`, `4500`, `2500` | расширить `_format_export` |
| «Имя таблицы из аргумента или сессии» — пролог 5 команд | `init.lua:1829, 2008, 2101, 2133, 2175` | `resolve_target()` |
| Определение адаптера по URL — 3 разошедшиеся копии, ни одна не знает про sqlserver | `init.lua:1621, 2505`, `ai.lua:248` | `adapters.kind()` / `display_name()` от `SCHEME_MAP` |
| Списки расширений файлов | `connections.lua:70, 114`, `init.lua:60` | одна константа |
| `vim.fn.input` + CANCEL-идиома — 36 раз в 10 файлах | везде | `ui.input()` / `ui.confirm()` |
| Карта «номер → view» — 3 копии, слоты 4-5 уже разошлись; числовая ветка `init.lua:1103` мёртвая | `init.lua:1101, 1445`, `query_pad.lua:518` | одна карта в `keymaps.lua` |
| scratch-буфер + botright split для отчётов | `diff.lua:408`, `profile.lua:386` | `ui.report_split()` |
| curl-пайплайн | `ai.lua:413`, `ai.lua:489` | локальный `post_json()` |
| `resolve_row_bp` есть, но обойдён 3 инлайн-копиями (у копий есть fallback, которого нет у хелпера — добавить флаг) | `view.lua:3193, 3443, 3625` | доработать хелпер |

## 4. Читаемость и структура

- **`view.lua:_setup_keymaps` — 3054 строки, ~90 замыканий** (`view.lua:2172-5226`). Безопасная декомпозиция по уже существующим секционным комментариям: `setup_edit_keymaps(bufnr, kmap)` и т.д. Это первопричина большинства дублей внутри файла (12 копий guard-а `is_editable`, 62 × `M._sessions[bufnr]`, две байт-в-байт одинаковые keymap-функции `view.lua:3362/3376`).
- **`init.lua:setup()` — ~900 строк**, из них ~300 — Query Doctor (`detect_adapter`, `TRANSLATIONS`, `_parse_explain_nodes`, `_render_query_doctor` объявлены *внутри* setup и пересоздаются при каждом вызове; недоступны тестам до первого `setup()`). Механический вынос на уровень модуля / в `explain.lua`.
- `get_opts()` (`init.lua:40-47`) перечисляет 10 полей вручную — новая опция молча станет `nil`; `vim.deepcopy(OPTS)`.
- Мёртвый код: `connections.lua:163` (`mask_url`), `ai.lua:326` (`sql_kw`), `ai.lua:6` и `properties.lua:6` (неиспользуемые require), `mysql.lua:59-75` (детект MariaDB — используется только тестами, удалять вместе с ними), `view.lua:628-638` (вычисленный и выброшенный `cell_hl`), `profile.lua:240`.
- Byte-длина вместо display-ширины (съедет на не-ASCII): `profile.lua:230, 282`, `diff.lua:179, 197`, `properties.lua:111-153`, `er_diagram.lua:99`.
- `pickers/telescope.lua:5` и `snacks.lua:5` — «мёртвые» require на самом деле load-bearing (на них падает `pcall` в `grip_picker.pick`) — **не удалять**, дописать комментарий.

## 5. Устаревшие API и совместимость

- `nvim_buf_add_highlight` (deprecated с 0.11, удаление в 0.13): `init.lua` ×9, `er_diagram.lua` ×6, `schema.lua` ×2, `view.lua:5437`. Замена `nvim_buf_set_extmark` работает на 0.10 — мигрировать одним проходом.
- `view.lua:3555` — единственный `nvim_win_set_option`; → `nvim_set_option_value(..., { win = pwin })`.
- `init.lua:1553` — `vim.validate` в старой форме: **не трогать**, новая сигнатура требует 0.11, а минимум — 0.10. Оставить TODO.
- `ui.lua` — `nvim__redraw` (приватный API): осознанно, оставить.

## 6. С чего начать (рекомендуемый порядок)

1. **Баги-однострочники:** `duckdb.lua:51` (экранирование DSN), `pcall` в `run_cmd`, `s.total_rows` в `view.lua:5060`, `GripColType`, buf-valid-guard в `query_pad.lua:125`.
2. **Форматтер** `format.lua` — перенос трёхсимвольной ветки + расширение списка операторов (есть `_format_lua` для юнит-теста).
3. **Перфоманс-двойка:** мемо `col_idx` в `data.lua` + ранний выход в CursorMoved-хайлайте. Максимальный эффект на больших таблицах при минимальном диффе.
4. **`GripExplain` без аргумента** в `view.lua:1914/4642` и фикс `ga`.
5. **Удаление копий с готовым API:** `fetch_view_fk` и `ddl.drop_table` → `db.get_referencing_foreign_keys`; `mysql_exec` → удалить; `ensure_row_count` → `sql.quote_ident`.
6. **Общий слой:** `sql.escape_literal` + `split_table_name` + `parse_dadbod_url`; `ui.input`/`ui.confirm`/`ui.info_float`; `paths.lua`. Чисто механические замены, SQL и поведение не меняются.
7. **Декомпозиция** `_setup_keymaps` и вынос Query Doctor из `setup()` — самый большой выигрыш в читаемости, делать отдельным PR без функциональных правок.
8. **Миграция `nvim_buf_add_highlight`** одним проходом по всем модулям.

Пункты 1–6 безопасны (поведение сохраняется, тесты в `tests/spec/` покрывают форматтер, экспорт, `data.lua`, slack/snap в `view.lua`). Пункты 1.6 (CASCADE) и `sqlserver` NOCOUNT требуют решения, потому что меняют видимое поведение.

---

## 7. План выполнения (для новой сессии)

Этот документ — единственный вход для исполнителя. Все находки выше содержат `file:line` на коммите `c794939`; статус верификации указан в тексте (раздел 1 перепроверен вручную, остальное — по отчётам агентов: перед правкой перечитай место в коде).

### Проверка

- Все тесты: `just test` (328 specs, headless nvim). Прогонять **до начала** (зафиксировать зелёную базу) и после каждого шага.
- Один спек: `just spec <name>` (например `just spec data`, `just spec adapter`).
- Линт: `just lint` (если luacheck установлен).
- Для перфоманс-правок (шаг 3) достаточно `just spec data`, `just spec view_snap`, `just spec grid_reuse` + полный прогон в конце.

### Шаги = отдельные коммиты (conventional commits, как в истории: `fix(...)`, `refactor(...)`)

| # | Коммит | Содержание | Тесты-стражи |
|---|---|---|---|
| 1 | `fix(duckdb): escape DSN in attach prefix` | §1.3 — одна строка | adapter_spec |
| 2 | `fix(adapters): never throw when CLI binary is missing` | §1.2 — pcall в run_cmd | adapter_spec |
| 3 | `fix(view): mелкие дефекты` | §1.7 — total_rows, GripColType, buf-valid guard в query_pad | query_pad_spec |
| 4 | `fix(format): don't split multi-char PG operators` | §1.1 — с юнит-тестом на `->>`, `#>>`, `@>`, `<@`, `&&` | новый + format-тесты |
| 5 | `fix(view): run GripExplain without inline SQL argument` | §1.4 | — (ручная проверка) |
| 6 | `fix(view): ga aggregates full column in normal mode` | §1.5 | — |
| 7 | `perf(data): memoize column index map` + `perf(view): reuse display value, skip unchanged column highlight` | §2.1, §2.2, §2.3 | data_spec, grid_reuse_spec |
| 8 | `perf(db): use get_referencing_foreign_keys in fk view and drop_table` | §2.4 (view.lua + ddl.lua) | fk_reverse_spec |
| 9 | `refactor(sql): shared escape_literal / split_table_name / parse_dadbod_url` | §3 — механическая замена, SQL побайтово тот же | adapter_spec полностью |
| 10 | `refactor(ui): shared input/confirm/info_float helpers` | §3 | полный прогон |
| 11 | `refactor: dedupe adapter-detection, view maps, file-ext lists, resolve_target` | §3 + §4 (мёртвый код) | полный прогон |
| 12 | `refactor(view): split _setup_keymaps into sections; move Query Doctor out of setup()` | §4 — без функциональных изменений | полный прогон |
| 13 | `chore: migrate nvim_buf_add_highlight to extmarks` | §5 — один проход по всем модулям | полный прогон |

Шаги независимы сверху вниз: можно остановиться после любого. 12 — самый объёмный, делать последним из рефакторингов.

### Ограничения

- **Не менять поведение** нигде, кроме явно помеченных багов из раздела 1. Спорные пункты §1.6 (SQLite CASCADE) и §2 sqlserver-NOCOUNT — **пропустить**, они требуют решения мейнтейнера.
- Не трогать: `vim.validate` в `init.lua:1553` (минимум 0.10), `nvim__redraw` в `ui.lua`, load-bearing require в `pickers/telescope.lua:5` и `pickers/snacks.lua:5` (добавить только комментарий).
- Минимум Neovim — 0.10: не использовать API новее.
- Версию и теги не трогать — релизы делает мейнтейнер отдельно (`chore(release)`).
- При удалении `mysql_exec` и MariaDB-детекта удалить и покрывающие их тесты (`adapter_spec.lua:766-832`), иначе прогон упадёт.
- Ветку создать от `main` (например `refactor/code-review-2026-07`), в `main` напрямую не коммитить.

---

## 8. Что сделано (ветка `refactor/code-review-2026-07`)

Итог: **43 файла, +1809 / −1463**. `view.lua` −809 строк, `init.lua` −424, `ui.lua` +160. Новые модули: `explain.lua` (209), `paths.lua` (35).

### Баги

| § | Коммит | Заметки |
|---|---|---|
| 1.3 | `d7609f7` fix(duckdb): escape DSN in attach prefix | |
| 1.2 | `763a804` fix(adapters): never throw when the CLI binary is missing | ENOENT проверен эмпирически: код 1 вместо traceback |
| 1.7 | `88e92b7` fix: five small defects found in code review | `total_rows`, `GripColType`, buf-guard в query pad, refresh **видимых** гридов вместо произвольного, лимит 30 таблиц в `ai.lua` |
| 1.1 | `2d85f6e` fix(format): don't split multi-char PG operators | Longest-match таблицы OP3/OP2; +20 регрессионных тестов на `->>`, `#>>`, `@>`, `<@`, `&&`, `<<`, `>>`, `@@`, `!~*`, `<=>` |
| 1.4 | `b4e0256` fix(view): pass SQL to :GripExplain as a command argument | Табличная форма `nvim_cmd` — не расщепляет ни по `\n`, ни по `|` |
| 1.5 | `608b8ad` fix(view): ga aggregates the whole column in normal mode | Normal берёт всю колонку, для выделения — отдельный visual-маппинг |
| — | `45b3fd9` fix(view): one JSON pretty-printer | Найдено по ходу: `\n` не эскейпился и размазывал значение по float'у; отступы вложенных контейнеров съезжали; `[]` рисовался как `{}` |

### Производительность

| § | Коммит | Результат |
|---|---|---|
| 2.1, 2.2, 2.3 | `165f272` perf: resolve each cell once per render, skip unchanged column highlight | Рендер 400×20: **17.4 ms → 6.1 ms**, вывод побайтово идентичен. `j`/`k` больше не переставляют ~1000 extmark'ов |
| 2.4 (часть) | `963ee6d` perf(view): one query for inbound FKs in the FK view | Сверено с прежним сканом на живой `tests/seed_sqlite.db` |

### Рефакторинг

| § | Коммиты |
|---|---|
| 3 (SQL) | `8aaffbe` escape_literal (51 инлайн) + split_table_name (3 копии) · `6c59fca` parse_dadbod_url (2 копии) · `806203a` удалён `mysql_exec` + MariaDB-детект с тестами · `f214974` `bare_table_name` в sqlite (7 инлайнов) |
| 3 (UI) | `b8c62c9` info_float (5 сайтов) · `23d3de7` input/confirm (35 сайтов) · `948d01a` report_split (2 сайта) · `3764ac8` общая обвязка закрытия float'ов |
| 3 (прочее) | `7838344` `paths.lua` · `c2f64da` `adapters.kind`/`display_name` из `SCHEME_MAP` · `9266a77` `resolve_target` · `601ac28` одна карта вкладок · `dea2d92` один форматтер экспорта · `5c6ad02` инлайны через `resolve_row_bp` · `f29e014` `post_json` в `ai.lua` · `8af494e` одна константа расширений |
| 4 | `f7738d7` мёртвый код · `1d921e9` комментарий про load-bearing require в пикерах · `54baea1` `get_opts` = `vim.deepcopy(OPTS)` · `b4797a3` `_setup_keymaps` разбит на 10 секций · `2db6d38` Query Doctor → `explain.lua` |
| 5 | `0aef116` 18 вызовов `nvim_buf_add_highlight` → `nvim_buf_set_extmark` · `7b236ea` `nvim_win_set_option`, остатки `vim.loop` |

### Изменения поведения (все намеренные, кроме них — ноль)

Помимо багфиксов выше, поведение изменилось только там, где сведение **уже разошедшихся** копий этого требует:

- `c2f64da`: `sqlserver://`/`mssql://` перестали определяться как «SQLite» в подсказке `GripFill` и как «SQL» в промпте AI; `mariadb://` в `GripFill` больше не «SQLite», а «MySQL». Query Doctor теперь пишет `sqlserver` вместо `unknown` (на разбор не влияет — там ветвление только по postgresql/mysql/duckdb).
- `601ac28`: видимое поведение **не** изменилось — разошедшаяся пятая копия карты вкладок оказалась мёртвой (никто не передавал `opts.view` числом), поэтому она удалена, а не примирена.
- `45b3fd9`: вывод JSON в row view и FK-float изменился — это исправление дефекта, детали в теле коммита.

### Как проверялось

Полный прогон после каждого шага. Плюс снапшоты до/после там, где тесты слепы (базовый снимок снимался через `git worktree` на коммит-до-правок):

- рендер сетки — строки + все extmark'ы, побайтово;
- **126 маппингов** буфера во всех режимах после разбиения `_setup_keymaps` — дифф пустой, счётчик тот же (это и ловит ошибку в порядке секций, при которой один `lhs` молча перетирает другой);
- extmark'и sidebar (4), ER-диаграммы (57) и сетки (16) после миграции на extmark'и;
- каталожные запросы и входящие FK — на живой `tests/seed_sqlite.db`;
- загрузка всех модулей: падают только `pickers/telescope.lua` и `pickers/snacks.lua` (плагины не установлены — ровно тот load-bearing `pcall`-путь).

---

## 9. TODO на следующий проход

### Требуют решения мейнтейнера (не трогались осознанно)

- [ ] **§1.6 `DROP TABLE ... CASCADE`** — в SQLite это синтаксическая ошибка, в MySQL слово парсится и игнорируется (ложное ощущение каскада). Меняет генерируемый SQL.
- [ ] **`SET NOCOUNT ON` в `sqlserver.lua`** — подавляет `(N rows affected)`, который `execute` затем парсит, поэтому `affected` всегда 0. Убрать `NOCOUNT` или перестать парсить — выбор за тобой.
- [ ] **N+1 FK-скан в `ddl.drop_table`** — заблокирован первым пунктом. Перевод на `db.get_referencing_foreign_keys` сам по себе безопасен, но его результат решает, дописывать ли `CASCADE`, а батч-API матчит имена таблиц шире (bare-name), то есть `CASCADE` начал бы срабатывать чаще.

### Производительность (§2.4, §2.5 — в таблицу 13 шагов не входили)

- [ ] `db.parse_csv` — квадратичная сборка quoted-полей: `field = field .. qch` на каждый байт (`db.lua:51+`). Лечится `raw:find('"', i, true)` + `table.concat`. Больно на blob-ах.
- [ ] `ai.lua` — до 90 синхронных спавнов CLI (3 запроса × 30 таблиц) при сборке схемы, хотя `db.get_schema_batch` реализован у всех пяти адаптеров и **до сих пор не используется**.
- [ ] `sqlite.get_indexes` — процесс на каждый индекс (`PRAGMA index_info` в цикле, `sqlite.lua:301`). Сворачивается в один запрос через `pragma_index_info`.
- [ ] `completion.lua` — на каждый введённый символ конкатенация всего буфера + 4 прохода `gmatch`; кэша по `b:changedtick` нет. Плюс `warm_schema` — no-op для всех, кроме DuckDB (async-вариант есть только там), так что холодный кэш = блокирующий спавн CLI посреди набора.
- [ ] `connections.switch` — 4 чтения + 2 записи одного файла за переключение; `history.lua` полностью перезаписывает файл истории на каждый запрос, хотя JSONL позволяет append.
- [ ] `grip_picker.filtered_items()` — вызывается 5 раз за рендер.
- [ ] `view.truncate_display` — per-символьные `vim.fn.strdisplaywidth`/`strcharpart` в цикле (`view.lua:167+`); ASCII fast-path снял бы почти всё.

### Структура и корректность

- [ ] **Byte-длина вместо display-ширины** — поедет на не-ASCII. Подтверждено: `properties.lua:119` (`pad` считает `#s`). По отчётам агентов то же в `profile.lua`, `diff.lua`, `er_diagram.lua` — перепроверить перед правкой.
- [ ] `view.lua` всё ещё 5393 строки. `_setup_keymaps` разбита на 10 секций по 200-400 строк — следующий заход может вынести секции в отдельные модули (`view/keymaps_edit.lua` и т.д.).
- [ ] `M._sessions[bufnr]` — 109 вхождений, `is_editable` — 19. Разбиение на секции дало таблицу-контекст `ctx`, но сами обращения не сократило: аксессор вида `ctx.session()` убрал бы большую часть.
- [ ] Дубль `close()` + `WinLeave` в `json_tree.lua` и `editor.show_error` не сведён: в первом совпадает только `WinLeave`, во втором другая семантика (dismiss немедленно, три клавиши, `nowait`). Хелпер на четырёх булевых флагах читался бы хуже дублей — если сводить, то менять сами сценарии закрытия.

### Тестовое покрытие (пробелы, найденные по ходу)

- [ ] **Welcome-экран не проверяется в headless** — подсветки применяются через `vim.schedule` и без UI не создаются, поэтому снапшот extmark'ов там пустой. 9 из 18 миграций на extmark'и пришлись именно на него и проверены только чтением диффа. Нужен тест, который дёргает функцию отрисовки напрямую.
- [ ] Float-окна почти не покрыты юнит-тестами — `ui_spec` вырос с 6 до 26 тестов, но `info_float`/`dismiss_float` проверялись одноразовыми снапшот-харнессами. Их стоит перенести в `tests/spec/`.
- [ ] MySQL, PostgreSQL, DuckDB и SQL Server эмпирически не проверялись: `duckdb` не установлен, PG-сервер не запущен. Живьём гонялся только SQLite. Перед релизом стоит поднять остальные (`seed-pg`, `seed-mysql`, `seed-duckdb` в `justfile`).
