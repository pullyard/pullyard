# PullYard Desktop — план редизайна (macOS, с переносом на Windows и Linux)

Итоговый документ дизайн-совета. Состав: ведущий дизайнер, дизайнеры A (нативный macOS, HIG, Liquid Glass), B (бренд и motion), C (плотность и эргономика профессионального инструмента), UX-flow дизайнер, продуктовый стратег и red team.
Все ссылки `file:line` указаны относительно корня репозитория и перепроверены ведущим на 2026-11-25. Скриншоты лежат в `docs/ux-overhaul/screenshots/macos/after/`.

Обозначения:
- **[A]** — аддитивное изменение (добавляем или полируем, ничего не убираем).
- **[спросить владельца]** — изменение что-то убирает, перекрашивает или переносит существующий элемент. Без согласия владельца не делаем.

---

## 1. Вердикт

PullYard технически сильнее, чем выглядит. В коде уже есть readiness по правилам веток, interdiff «с момента вашего ревью», CODEOWNERS, граф стеков, «Fix with agent», pull-to-refresh с рисующимся логотипом и навигационная память. Но экраны, на которых пользователь проводит 95% времени (инбокс, PR, diff, шиты merge и review, настройки), выглядят как аккуратный, но обезличенный SwiftUI-клиент GitHub. Бренд остался только в сплэше, логине и разделе Agents. На ключевых экранах нет ни логотипа, ни волны, ни осмысленного кораллового цвета. Каждое действие заканчивается тишиной: после merge или approve нет ни тоста, ни перехода дальше. Главный экран вводит в заблуждение: в заголовке окна написано «Review requests · 3 results», хотя открыт PR, в тулбаре два ↻ рядом, а «проваленный CI» нарисован красным ✕, который читается как «удалить строку».

На macOS 26 приложение выглядит как кросс-платформенное в маковском костюме. Оболочка собрана вручную из `HStack` с непрозрачными заливками. Тулбар закрашен `syBar`, поэтому системные стеклянные капсулы висят на плоской полосе. Liquid Glass нет нигде: `glassEffect` и `#available(macOS 26` в `Sources/` встречаются 0 раз. Плюс шесть-семь мелких «самодельных» деталей, которые вместе и дают ощущение «не вау».

**Ключевые причины:**

1. **Бренд не доходит до рабочих экранов.** Пустая деталь, самая большая площадь в приложении, — это generic `IconTile("arrow.triangle.pull")` (`Sources/PullYard/App/RootView.swift:188`, `main-laptop-light.png`). При этом `DrawnLogoMark` уже есть (`Sources/PullYard/Shared/Utilities.swift:375`).
2. **Тулбар врёт и шумит.**
   - Два ↻ и обрезанное «just now»: `Sources/PullYard/Features/PR/PRDetailView.swift:228-242` вкладывает `RefreshStatus`, который рисует свой `arrow.clockwise` (`Sources/PullYard/Shared/Refresh.swift:31`), плюс отдельный спиннер (`PRDetailView.swift:231`).
   - Заголовок окна берётся из списка, а не из PR.
   - Merge показывается даже на PR с конфликтами, потому что `canMerge` = `pr.isOpen && !pr.isDraft && model.canWrite` (`PRDetailView.swift:222-224`).
3. **Статусы нарисованы двусмысленно.**
   - CI failed — голый красный `xmark` (`Utilities.swift:278`).
   - Draft — `pencil.circle` внутри круга (`Utilities.swift:184` + `:241`), читается как ⊘.
   - Бейдж «✕1 ✓0» без слов (`PRDetailView.swift:697-699`).
   - Один и тот же failing check показан в четырёх местах.
4. **Diff выглядит любительским.**
   - `" +"` нарисован на каждой комментируемой строке (`Sources/PullYard/Shared/DiffTableView.swift:206`, `:233`), поэтому строки выглядят как «53 + +».
   - Контраст номеров строк 2.51:1 и 2.41:1 (`syGutter`, `Sources/PullYard/Shared/Theme.swift:106`).
   - Wrap включён по умолчанию (`Sources/PullYard/Features/PR/FilesTab.swift:12`).
   - До первой строки кода уходит около 40% высоты окна.
5. **Спиннеры вместо логотипа.** 26 вызовов `ProgressView(` в 19 файлах, из них 25 неопределённых. Это прямое нарушение правила владельца.
6. **Нет завершённости действий.** Merge и review закрываются молча (`Sources/PullYard/Features/PR/PRDetailModel.swift:768-786`). Тосты не кликабельны (`Sources/PullYard/Shared/ShortLink.swift:73`) и живут 1.8 с (`Sources/PullYard/App/AppModel.swift:910`). Undo нет, «Next PR» нет.
7. **Строки списка рассчитаны на «спокойный» режим, а не на triage.** Три строки на PR, около 73 pt (`Sources/PullYard/Features/Lists/SearchListView.swift:555-601`). На экране помещается примерно 10 PR. Ни review-статуса словами, ни j/k.

---

## 2. Проблемы по областям

### 2.1 Оболочка, сайдбар, тулбар

| # | Проблема | Доказательство |
|---|---|---|
| S1 | Оболочка — ручной `HStack` + `ColumnResizeHandle` с непрозрачными `.surface(...)`. Нет системного стеклянного сайдбара, а заголовок окна приходит не из той колонки. | `App/RootView.swift:115-139` (resize-ручки `:124`, `:130`); заливки `Shared/Theme.swift:76-78` |
| S2 | Строки сайдбара — `Button`, выделение нарисовано вручную. Нет навигации стрелками, type-select и серого выделения в неактивном окне. Accessibility-трейты при этом есть. | `RootView.swift:458`, `:493-499` |
| S3 | Тулбар закрашен непрозрачным `syBar`, поэтому стекло Tahoe лежит на плоской полосе. | `RootView.swift:532-536`; `pr-detail-dark.png` |
| S4 | Заголовок окна «Review requests · 3 results» при открытом PR. `navigationTitle` PR проигрывает списку. | `PRDetailView.swift:79-80` против `SearchListView.swift:407-408` |
| S5 | Двойной refresh и спиннер в тулбаре PR; Tahoe склеивает «Fix with agent» и «Merge» в одну капсулу. | `PRDetailView.swift:228-242`, `Refresh.swift:132-141`; `pr-detail-dark.png` |
| S6 | Шорткаты Approve, Review и Merge висят на невидимых кнопках `.opacity(0)`, поэтому в меню их не найти. | `PRDetailView.swift:103-118` |
| S7 | Одно окно, без вкладок и без «Open in New Window». | `App/PullYardApp.swift:47` (`Window("PullYard", id: "main")`) |
| S8 | Иконки сайдбара — глиф 10.5 pt в фиксированной плитке 21 pt с белым скосом в стиле Big Sur. Плитка не масштабируется. | `RootView.swift:518-528` |
| S9 | В компактном рейле заголовки секций превращаются в линии по 1 px, а бейджи наезжают на глифы. | `RootView.swift:423-424`, `:464-475`; `main-small-light.png` |
| S10 | Коралловый цвет перегружен: агент, папка «My PRs by project», CTA. | `RootView.swift:349`, `Theme.swift:130` |

### 2.2 Списки и инбокс

| # | Проблема | Доказательство |
|---|---|---|
| L1 | Три строки на элемент даже при однострочном заголовке; автор повторяется в «Created by me». | `SearchListView.swift:555-601` |
| L2 | Статус review — иконка 10 pt без текста; CI — голый ✕ справа, похожий на кнопку «убрать». | `SearchListView.swift:578-582`, `:615-620`; `Utilities.swift:278` |
| L3 | Сегмент «Open» в тёмной теме: белый на #5BB8EC, контраст 2.2:1. | `SearchListView.swift:333-337`; `main-laptop-dark.png` |
| L4 | Плейсхолдер «Filter: text, repo:org/name…» выглядит как глобальный поиск, хотя фильтрует только текущий список. | `SearchListView.swift:406` |
| L5 | Review requests — это результат поиска, а не очередь: нет «Your turn», «Re-review», «Waiting». | `SearchListView.swift:578-582` |
| L6 | Уведомления помечаются прочитанными при простом выделении стрелкой. Это баг triage. | `Features/Notifications/NotificationsView.swift:93-97` |
| L7 | «Done» в уведомлениях есть только в контекстном меню; иконка с `.system(size: 11)` в обход TextZoom. | `NotificationsView.swift:36`, `:206` |

### 2.3 PR detail

| # | Проблема | Доказательство |
|---|---|---|
| P1 | Хедер, ReReview, ClaudeFix, CI-баннер и TabStrip идут стопкой и не схлопываются на Files. | `PRDetailView.swift:58-62` |
| P2 | Две кнопки «Fix with agent» с разным смыслом: в тулбаре — комментарии ревью, в баннере — CI. | `PRDetailView.swift:267-271`, `Features/ClaudeFix/CIFixBanner.swift:52-55` |
| P3 | Конфликты — тупик. «View 6 conflicts» скроллит разговор вниз, а действие с агентом спрятано. | `PRDetailView.swift:601-607` |
| P4 | `canPerform` возвращает false для `.updateBranch` и `.readyForReview`. | `PRDetailView.swift:665` |
| P5 | Бейдж чеков всегда рисует ✓ даже при 0. | `PRDetailView.swift:699` |
| P6 | Запуск агента выбрасывает пользователя из PR в раздел Agents. | `Features/ClaudeFix/ClaudeLaunchControls.swift:9`, `CIFixBanner.swift:46-49` |
| P7 | Фокус в TabStrip не виден; underline — `syAccent`. Underline оставляем. | `Shared/TabStrip.swift:55-61` |

### 2.4 Files / diff

| # | Проблема | Доказательство |
|---|---|---|
| D1 | Постоянный `" +"` в гаттере. | `DiffTableView.swift:206`, `:233`; `diff-light.png` |
| D2 | Контраст гаттера 2.51:1 (light) и 2.41:1 (dark). | `Theme.swift:106` |
| D3 | Wrap включён по умолчанию; настройка общая с commit-diff. | `FilesTab.swift:12`, `Shared/DiffLayout.swift:4` |
| D4 | Список файлов фиксированной ширины 260; строки в две линии; прогресс «0/17» показан мелким серым. | `FilesTab.swift:21`, `:398` |
| D5 | Hunk-навигация использует `arrow.up.to.line` («наверх»), что вводит в заблуждение. | `FilesTab.swift:150-151` |
| D6 | Нет intraline-подсветки, раскрытия контекста и диапазонов комментариев. | grep по `Sources/` — 0 совпадений; `Diff.swift:50-54` |
| D7 | Diff — это AppKit `NSTableView` в `NSScrollView`. SwiftUI-модификаторы scroll-edge до него не дотягиваются. | `DiffTableView.swift:342`, `:403`, `:442` |
| D8 | Во встроенном композере выделена «Add single comment» (постит сразу), а ⌘↩ вызывает «Add to review». | `FilesTab.swift:763-769` |

### 2.5 Agents

- «Working» показан тремя разными языками:
  - `ProgressView` mini — `Features/Claude/ClaudeStatus.swift:168`, `Features/Claude/ClaudeViews.swift:538`;
  - CALayer-спиннер в `ClaudeStatus.swift`;
  - `WakeLoader` — `Shared/LogoLoader.swift:225`.
- Дублирующий enum `BrandMark` со своими цветами корпуса (`ClaudeStatus.swift:213-219`).
- Пользовательские строки «Claude Code»:
  - `ClaudeViews.swift:287`;
  - `Features/PR/StackTab.swift:802`, `:911`;
  - `CIFixBanner.swift:71`;
  - `App/SettingsView.swift:219`;
  - `Auth/AccountSwitcher.swift:48`.
- Скриншоты Agents размыты, поэтому раздел оценивался только по коду. Транскрипт, инспектор и таб-бар визуально никто не ревьюил. Это пробел, см. раздел 6, Фаза 3.

### 2.6 Шиты merge и review

- **Merge** (`merge-sheet-light.png`):
  - показывает одну строку `readiness.text` (`Features/PR/PRSheets.swift:155`);
  - на конфликтном PR красная «Merge anyway» стоит как primary (`PRSheets.swift:183-193`);
  - нет `.defaultAction`, поэтому Return ничего не делает;
  - `MergeRequirementsList` существует, но в шит не встроен.
- **Review**:
  - решение выбирается radioGroup (`PRSheets.swift:100-105`), по умолчанию «Comment» (`:80`);
  - Submit выключен без объяснения (`:124`);
  - вместо списка ожидающих комментариев только счётчик (`:94-96`).

### 2.7 Настройки

- Выбранная вкладка в системном синем, тогда как тоглы — sky. У сцены нет `.tint` (`settings-dark.png`).
- Заголовок секции «Claude Code» (`SettingsView.swift:219`).
- Нет About-блока с логотипом.

### 2.8 Логин и онбординг

- Форма появляется только через ~1.95 с (`Auth/LoginView.swift:174`), сплэш рисуется ~1.05 с (`App/SplashView.swift:32-33`).
- Карточки входа равного веса.
- Спиннер на `LoginView.swift:162`.
- Вордмарк — плоский SF Bold 36 (`LoginView.swift:376`).
- После входа пользователь попадает в часто пустые Review requests без единой подсказки.

### 2.9 Командная палитра

- Только навигация и системные действия (`Features/Palette/CommandPalette.swift:495-560`). Нет Approve, Merge, Fix with agent, Mark viewed.
- Фон — материал плюс `syPanel` 0.72 (`CommandPalette.swift:176-177`), без учёта Reduce Transparency.

### 2.10 Уведомления

- Описаны в L6 и L7. Дополнительно:
  - уведомления не группируются по PR;
  - форма статусной иконки (скруглённый квадрат, `NotificationsView.swift:209`) не совпадает с кругом в PR-списке.

### 2.11 Состояния: загрузка, пусто, ошибка

- **25 неопределённых спиннеров** (полный список: `grep -rn "ProgressView(" Sources/PullYard`). Среди них:
  - `Refresh.swift:28`;
  - `SearchListView.swift:285`, `:442`;
  - `Features/MenuBar/MenuBarView.swift:36`;
  - `StackTab.swift:817`, `:891` (через `scaleEffect(0.7)`);
  - `Features/ClaudeFix/FixWithClaudeSheet.swift:198`, `:241`, `:416`;
  - `Utilities.swift:519`;
  - `Features/Issue/IssueDetailView.swift:167`;
  - `Features/Repos/RepoCodeView.swift:190`;
  - `Features/Update/UpdateView.swift:55`;
  - `Auth/UnlockView.swift:81`.

  `UpdateView.swift:109` — определённый прогресс, его оставляем.
- **Цикл `PullYardLoader` длится 2.75 с** (`LogoLoader.swift:197-199`). Для быстрых загрузок это слишком долго: пользователь видит недорисованный узел.
- **Ошибка рефреша.** Любая ошибка в компактном варианте показывается как «Offline» (`Refresh.swift:57`), включая 401 и rate limit.
- **Где нет refresh:**
  - у Jira (`Features/Jira/JiraViews.swift:116`, только `.task`);
  - у браузера кода `RepoCodeView`.

  Оба случая нарушают правило «refresh везде».

### 2.12 Motion

- `Motion.reduced` — вычисляемое свойство, но за изменениями не следит (`Shared/Motion.swift:5`). Используется в 28 местах. `@Environment(\.accessibilityReduceMotion)` используется только в `LogoLoader.swift:200`.
- Слайд строк на 60 pt (`Shared/RowAppear.swift:105`) — слишком тяжело для плотного списка.
- Около 12 «сырых» кривых вне `Motion.swift`, например сплэш `.spring(0.6, 0.72)` (`SplashView.swift:26`).
- `symbolEffect`, `contentTransition`, `phaseAnimator` — 0 использований.

### 2.13 Доступность

- Increase Contrast игнорируется: `Theme.swift:65` матчит только `.darkAqua` и `.aqua`.
- `syDim` даёт 3.33:1 (light) и 4.02:1 (dark).
- Белый текст на `syCoral` dark — 2.97:1 (кнопка в CI-баннере).
- Доступность внутри AppKit-таблицы diff (VoiceOver, фокус) не описана ни в одном спеке.

---

## 3. Разногласия совета и решения лида

| Тема | A (нативный) | B (бренд) | C (плотность) | Red team | **Решение лида и почему** |
|---|---|---|---|---|---|
| Миграция оболочки | `NavigationSplitView` сразу | после токенов и лоадера | только через спайк | спайк за флагом | **Спайк в Фазе 3.** Сначала делаем то, что видно сразу и не ломает рейл, EdgeReveal и ширины: сайдбар `List(selection:)`, тулбар, заголовок окна — на текущем `HStack`. |
| Стекло тулбара на 26 | убрать краску `syBar` | убрать | убрать | только после спайка AppKit edge | **Согласен с red team.** Diff и разговор — AppKit и WKWebView (`DiffTableView.swift:342`, `Shared/HTMLView.swift:4`), `.scrollEdgeEffectStyle` на них не действует. До успешного спайка на экранах PR краска остаётся, на списках и в настройках снимаем. |
| Тинт стеклянного сайдбара | 0% (только канва) | 60% `sySidebar` | 30–40% | 30–40% | **30–40%, только macOS 26**, окончательно по скриншотам в обеих темах. При 60% стекло становится непрозрачным, при 0% теряется тёплая бумага и navy. |
| Смысл кораллового | бренд, агент, «твой ход» | primary-действие везде | агент и «нужно твоё действие» | плюс исключение для CTA логина | **Коралл = «действуешь ты или твой агент»**, плюс CTA логина (совпадает с сайтом, `docs/index.html:111`). Merge и Approve — зелёные, Request changes — красный, выделение, ссылки и фокус — sky. Максимум одна коралловая *заливка* на вид. |
| Подчёркивание TabStrip в коралл | — | да | — | нет | **Нет.** Коралл на каждом экране PR размывает его смысл. Underline остаётся `syAccent`. |
| Поверхность ревью | шит → нижний док → инспектор | карточки вердикта | правая панель 320 pt | шит S, затем панель | **Шаг 1 (Фаза 1):** шит с сегментированным вердиктом. **Шаг 2 (Фаза 3):** правая панель-инспектор, общая с «Agent run». Нижний док не делаем. |
| Навигация по diff | плавающий стеклянный HUD | HUD с иконками | в строку табов | ни то, ни другое | **Ни HUD, ни строка табов.** HUD закрывает код, а строка табов не помещается на 1024 pt. Утончаем `reviewBar` до 28 pt с правильными символами, на Files он вливается в свёрнутую плашку PR. |
| Иллюстрация ошибки | треугольник | наклонённый корабль | наклонённый корабль | треугольник | **Треугольник плюс типизированная причина.** Логотип не должен означать сбой. Корабль появляется только в нейтральных, пустых и успешных состояниях. |
| Индикатор состояния строки | глиф | круг | полоса 3 pt | круг без кольца | **Круг без внутреннего кольца в Comfortable, глиф в Compact, без полосы.** Полоса конфликтует с 3-pt полосой выделения. |
| Цвет «+» комментария | accent | коралл | коралл | коралл | **Коралл**, только при hover или фокусе. Это действие ревьюера. |
| Модель Undo | `UndoManager` | — | без задержки для коммента | отложенный коммит | **Отложенный коммит (5 с)** для Done в уведомлениях и удаления ветки: `DELETE /notifications/threads/{id}` необратим (`API/GitHubAPI+Endpoints.swift:237-239`). ⌘Z отменяет ожидающий коммит. Для комментов основной кнопкой делаем «Add to review». |
| Заголовок окна | title + subtitle | title + subtitle | breadcrumb | title + subtitle | **Title = заголовок PR, subtitle = `owner/repo #N · <список>`**, плюс кнопки ‹ › в тулбаре. Breadcrumb — не маковская идиома. |
| Кривая бренда | 0.16,1,0.3,1 | существующая 0.22,1,0.36,1 | 0.16,1,0.3,1 | существующая | **Существующая** (`Motion.swift:11-12`). Разница незаметна, а замена — лишний churn. |
| Длительность «празднования» | ≤900 мс | ≤900 мс | ≤700 мс, после 3-го merge затухает | C | **≤700 мс**, только внутри тоста и state pill, никогда не блокирует ввод. |
| Визуал readiness | кольцо из 4 сегментов | кольцо вокруг «буя» | подписанные микро-чипы | чипы | **Подписанные микро-чипы** в полном хедере; кольцо 12 pt — только в свёрнутой плашке. |
| Клавиша «следующий в очереди» | ⌥⌘↓ | ⌘] | — | ⌥⌘↓ | **⌥⌘↓ / ⌥⌘↑.** ⌘] — это Forward (`PullYardApp.swift:87-88`), ⇧⌘] — Next Session (`:103`). |
| Режимы плотности | 3 (как в Mail) | 2 | 2 | 3 | **3 значения в одном пикере.** У существующих пользователей остаётся «Roomy» (сегодняшние 3 строки), у новых — «Standard» (2 строки). |
| Карточки вердикта | сегменты | карточки | сегменты | сегменты | **Сегментированный контрол.** Карточки съедают ~120 pt. |
| Serif display | только hero | hero + заголовки колонок | только hero | — | **New York только в hero:** сплэш, логин, пустые состояния, тост завершения, About. |
| j/k без открытия | — | — | курсор без открытия | j/k = ↑/↓ с дебаунсом | **j/k ведут себя как ↑/↓ и открывают PR с дебаунсом 150 мс.** Отдельный курсор потребует рефакторинга `SearchListView.swift:358`. |
| Боб героя-логотипа | — | бесконечно | — | 2 цикла | **Два цикла и стоп**, повтор только при простое окна в фокусе. |
| Автоскрытие футера | — | — | было | против | **Футер остаётся всегда.** Правило «refresh везде». |
| Шорткаты окон | ⌥⌘O | — | — | ⌥⌘O new window, ⇧⌘O браузер | **⌥⌘O — новое окно, ⇧⌘O — браузер.** Оба свободны, проверено grep по `keyboardShortcut(`. |
| Ссылка (link) | `#1D70A6` | `#1F6FA3` | `#1F6FA3` | — | **`#1F6FA3`** (5.30:1, совпадает с `--sky-ink` сайта, `docs/index.html:50`). |

---

## 4. Целевая дизайн-система

### 4.1 Цветовые токены

Brand-режим. В режиме System всё остаётся на системных цветах, как сейчас (`Theme.swift:62-67`). Контраст посчитан по WCAG. **B** — брендовый токен. «Твик» означает сдвиг значения: это полировка, но владельцу сообщаем.

| Токен | Light | Dark | Роль / контраст | Статус |
|---|---|---|---|---|
| `syWindow` (B) | F7F5F0 | 0C1220 | канва; на 26 — `containerBackground(.window)` (macOS 15+) | без изменений |
| `sySidebar` (B) | EFECE5 | 0A0F1B | ≤15 непрозрачно; на 26 тинт стекла 30–40% | без изменений |
| `syList` / `syPanel` | F3F1EC / FDFCFA | 0E1526 / 101828 | плотные поверхности чтения, всегда непрозрачные | без изменений |
| `syRaised` / `sySunken` | FFFFFF / F1EEE8 | 152036 / 0A101C | поля ввода внутри стекла, фон гаттера, треки | без изменений |
| `syBar` | F5F3EE | 111A2C | тулбар на ≤15; на 26 — после спайка | без изменений |
| `syLine` / `syLineStrong` | 1A2333 @.12 / .20 | A0AEC4 @.14 / .22 | как в iOS (`ios/PullYardMobile/AppTheme.swift:97-98`) | твик (было .08/.10 и .15/.18) |
| `syText` | 1A2333 | E6EBF2 | | без изменений |
| `syMuted` | 5F6B7E | 8693A8 | | без изменений |
| `syDim` | **646C80** (4.65) | **7D899F** (5.16) | третичный текст | твик (было 3.33 / 4.02) |
| `syGutter` | **687084** (4.83) | **7D899F** (5.03) | номера строк diff | твик (было 2.51 / 2.41) |
| `syAccent` (B, sky) | 2A8BC8 | 5BB8EC | выделение, фокус, underline; не для текста на заливке | без изменений |
| `syLink` | **1F6FA3** (5.30) | 5BB8EC | текст ссылок на панелях | новый |
| `syAccentFill` | 1D70A6 | 1D70A6 | любой залитый sky-контрол с белым текстом (5.36), включая сегмент «Open» | расширение применения |
| `syCoral` (B) | D8513F | EE6F5F | глифы, контуры, «+» комментария, точка непрочитанного | смысл сужен |
| `syCoralInk` | **B8412F** (5.34) | EE6F5F | коралловый текст в чипах (`--coral-ink` сайта) | новый |
| `syCoralFill` (B) | **C24533** | **EE6F5F** | единственный залитый коралловый CTA на вид | новый |
| `syOnCoral` | FFFFFF (5.01) | **1A0B09** (6.46) | текст на `syCoralFill`; в тёмной теме чернила как `--on-coral` сайта | новый |
| `syViolet` (B) | 6B55D6 | 9D8CF0 | merged + логотип | без изменений |
| `syGreen` / `syGreenFill` | 2E8A57 / 2B7F50 (белый 4.94) | 5DBE8A / 2B7F50 | passing, approve, merge | без изменений |
| `syRed` / `syRedFill` | C2412F / B23A2A (белый 5.95) | E8746A / B23A2A | failing, request changes | без изменений |
| `syAmber` / `syAmberInk` | B7791F / **9A6416** (4.87) | E8B44C | ожидание, устаревшие данные; amber 3.55 — только иконки | Ink новый |
| `syBrandGradient` (B) | 5E48C9 → 1F6FA3 → B8412F | 9D8CF0 → 5BB8EC → EE6F5F | только hero, пустые состояния, логин, успех (`docs/site/site.css:336`) | новый |
| `syHarborLine` (B) | 1F6FA3 @.22 | 7DD3FC @.20 | линия воды в пустых состояниях | новый |
| `syWake` (B) | 1F6FA3 @.55 | 7DD3FC @.75 | след в моменте merge, wave-sweep загрузки | новый |
| `diff.addWord` / `delWord` | оттенок add/del @.28 | @.30 | intraline-подсветка | новый |
| `diff.changeBar` | green / red / coral, 3 pt | то же | левый край гаттера | новый |

**Increase Contrast.** Расширяем `Theme.color` (`Theme.swift:62-67`) на `.accessibilityHighContrastAqua` и `.accessibilityHighContrastDarkAqua`:
- линии ×2 по alpha;
- `syDim` и `syGutter` берут значение `syMuted`;
- заливки темнее на 8% по L;
- у чипов граница 1 px.

**Порты.** Windows: те же ключи в `Brand.xaml` / `Palette.cs`, плюс `AccessibilitySettings.HighContrast`. Linux: CSS-переменные в `theme.rs`, плюс `adw::StyleManager::is_high_contrast()`.

**Совместимость с iOS.**
- iOS `accentFill` dark `0x2580C0` даёт 4.26:1 — ниже AA (`ios/PullYardMobile/AppTheme.swift:110`). iOS должен перейти на `1D70A6`.
- iOS coral и violet (`AppTheme.swift:104-105`) отличаются от macOS и сайта. Источником истины считаем macOS и сайт, они совпадают с `docs/index.html:27`.
- Единый генератор `brand.json` откладываем на Фазу 3.

### 4.2 Типографика

Всё проходит через `TextZoom`.

| Роль | Шрифт | Размер / вес / интерлиньяж | Где |
|---|---|---|---|
| `display` | New York semibold | 28 / 34 | пустые состояния, тост завершения, About |
| `wordmark` | New York semibold | 36 | сплэш (`SplashView.swift:14`), логин (`LoginView.swift:376`) |
| `prTitle` | SF Pro semibold | 20 / 26 | полный хедер PR |
| `barTitle` | SF Pro semibold | 13 / 16 | свёрнутая плашка PR |
| `rowTitle` | SF Pro medium | 13 / 17 | строки списков |
| `body` | SF Pro | 13 / 18 | |
| `meta` | SF Pro, `monospacedDigit` | 11 / 14 | вместо 10-pt `syCaption` для чисел, которые сканируют глазами |
| `chip` | SF Pro semibold | 11 / 13 | чипы |
| `eyebrow` | SF Pro semibold uppercase, +0.06em | 10, `syMuted` | заголовки секций; коралл только в hero |
| `monoMeta` | SF Mono | 11 | `repo#123`, ветка, `+24 −6` |
| `code` / `gutter` | SF Mono | 12/17 и 11 | diff, логи |
| `keycap` | SF Mono medium 11 на `syRaised` + `syLineStrong` | | подсказки шорткатов |

**Порты:**
- Windows: Segoe UI Variable / Cascadia Mono / Sitka.
- Linux: Cantarell или системный шрифт / Source Code Pro / Noto Serif.

Шрифты не скачиваем.

### 4.3 Отступы, плотность, радиусы, материалы

- **Spacing.** 2 · 4 · 6 · 8 · **10** · 12 · 16 · **20** · 24 · **32** (жирные — новые, к `Theme.swift:154-162`). В новом коде литералы вне шкалы запрещены.
- **Плотность:**

| Режим | Высота строки | Вертикальный padding | Строк |
|---|---|---|---|
| Compact | 28 | 4 | 1 |
| Standard | ~52 | 6 | 2 (заголовок до 2 строк) |
| Roomy | как сейчас | | 3 |

  Строки файлов — 24, сайдбара — 28.
- **Радиусы.** `Radius` без изменений (`Theme.swift:164-171`):
  - чипы — capsule;
  - строки — 7;
  - карточки и баннеры — 10;
  - палитра и HUD — 14;
  - шиты — системные.

  На 26 плавающее стекло использует `ConcentricRectangle`.
- **Elevation:**
  - e0 — канва;
  - e1 — список и панель, непрозрачные;
  - e2 — карточки: `syLine` 1 px, без тени;
  - floating — палитра, тосты, popovers: стекло на 26, на ≤15 `.regularMaterial` + `syLineStrong` + тень (0, 8, 24, black @.18);
  - modal — системный шит.
- Альфа-заливки поверх материала, например `syPanel` 0.72 в палитре, обязаны читать `accessibilityReduceTransparency` и становиться непрозрачными.

### 4.4 Motion-токены (`Shared/Motion.swift` v2)

| Токен | Значение | Применение |
|---|---|---|
| `Dur.micro` | 0.12 | hover, Done |
| `Dur.fast` | 0.18 | чипы, смена состояния |
| `Dur.base` | 0.24 | схлопывание хедера, underline |
| `Dur.slow` | 0.36 | панель, insert glow |
| `Dur.story` | 0.7 | празднование внутри тоста |
| `Spring.snappy` | (0.28, 0.86) | выделение, схлопывание |
| `Spring.bouncy` | (0.36, 0.72) | только штамп и пульс бейджа |
| `Spring.gentle` | (0.5, 0.9) | заполнение прогресса |
| `Spring.splash` | (0.6, 0.72) | сохраняем ощущение сплэша (`SplashView.swift:26`) |
| `Ease.brand` | `timingCurve(0.22, 1, 0.36, 1)` | существующая |

Правила:
- **Строки:** смещение 8 pt вместо 60 (`RowAppear.swift:105`), шаг 30 мс, максимум 8 строк, только при первой загрузке и никогда при live-refresh.
- **Логотип:** одна кривая для всех draw и erase — cubic in-out. Убираем косинус и квадратики (`LogoLoader.swift:118`, `:185`, `:221`, `Utilities.swift:408`).
- **Reduce Motion:**
  - во вьюхах читаем `@Environment(\.accessibilityReduceMotion)`;
  - в AppKit-коде подписываемся на `NSWorkspace.accessibilityDisplayOptionsDidChangeNotification`;
  - фолбэки: смещения → 0, пружины → crossfade 0.15 с, лоадеры → статичная марка 0.8 с подписью «Loading» (уже так в `LogoLoader.swift:203-205`), празднование → финальный кадр плюс тост.
- Около 12 сырых кривых переводим на токены (кодмод).
- **Порты:**
  - Windows: Composition `CubicBezierEasingFunction` / `SpringVector3NaturalMotionAnimation`, учитываем `UISettings.AnimationsEnabled`.
  - Linux: `adw::TimedAnimation` / `adw::SpringAnimation`, учитываем `gtk-enable-animations`.

### 4.5 Компоненты и состояния

**`PYLoader(style:)` — рисующийся логотип вместо спиннеров** (`Shared/LogoLoader.swift`):

| Стиль | Размер | Поведение | Заменяет |
|---|---|---|---|
| `.inline` | 12–16 pt | только две ветки, штрих `syAccent`, draw/erase 0.9 с, без заливки | все 25 неопределённых `ProgressView()` |
| `.block` | 32–48 pt | полная марка: draw 1.1 с → hold 0.3 → erase 0.4; старт с progress 0.3 | `LoadingView` (`Utilities.swift:328-340`) |
| `.hero` | 72–96 pt | один draw-on (stroke → fill), затем 2 цикла bob (±4 pt, 4.6 с, как `site.css`) и стоп | пустые состояния, логин |
| `.wake` | 20×12 | существующий `WakeLoader` | всё «agent working», включая CALayer-спиннер в `ClaudeStatus.swift` |

- Показываем через 180 мс, держим минимум 400 мс.
- `LinearProgress` (`SearchListView.swift:285`) превращается в волну 2 pt цвета `syWake`.
- `BrandMark` (`ClaudeStatus.swift:213`) делаем алиасом `LogoGeometry`; визуально ничего не меняется.
- **Windows:** `windows/src/PullYard/Controls/LogoLoader.cs`, анимация `StrokeDashOffset`.
- **Linux:** `linux/src/ui/logo.rs`, dash-offset через GtkSnapshot или Cairo.

**`RefreshPill` — refresh-аффорданс.** Один на окно, привязан к фронтальному скоупу: PR, если он открыт, иначе список.
- Анатомия: `[↻ | .inline-лого] 2m ago` с `.fixedSize()`.
- Состояния:
  - idle — `syMuted`;
  - refreshing — лоадер;
  - устарело больше 5 мин — `syAmberInk`;
  - ошибка — треугольник и *типизированная* причина: «Offline» (по `NWPathMonitor`), «Rate-limited until 14:02» (`rateLimitedUntil` уже есть), «Sign in again» с кнопкой, «Couldn't refresh · Retry».
- Клик или ⌘R обновляет скоуп, ⌥⌘R — всё.
- Кнопку списка (`Refresh.swift:132-141`) подавляем, когда деталь даёт свою пилюлю. Отдельный спиннер `PRDetailView.swift:230-232` вливается в пилюлю.
- Футер колонки остаётся (24 pt). Pull-to-refresh остаётся.
- Добавляем `liveRefresh` и `refreshTick` в Jira (`JiraViews.swift:116`) и `RepoCodeView`.
- **Windows:** статус-элемент в CommandBar. **Linux:** виджет в HeaderBar плюс `adw::Toast` для ошибок.

**`StatusChip`.** Те же метрики, что у iOS `ReasonChip` и `ReviewChip` (`ios/PullYardMobile/InboxAndPullsView.swift:197`, `:642`).
- Анатомия: capsule, высота 18, padding 6, глиф 10 pt, заливка Ink-цветом @12% (light) / 18% (dark), текст Ink-цветом.
- Hover: заливка до 20% и тултип. Increase Contrast: граница 1 px.

| Тип | Варианты |
|---|---|
| CI | `✓ 12` green · `✕ 1 of 12` red (`xmark.circle.fill`, никогда голый ✕) · `◌ 3` amber (`circle.dashed`, на 26 вращается, если motion разрешён) |
| Review | «Your turn» (`syCoralInk`) · «Re-review · 3 new» (`syCoralInk`) · «Approved» (green) · «Changes requested» (red) · «Waiting 2d» (`syAmberInk` после 24 ч) · «Draft» (slate outline) · «Agent draft» (коралловый outline) |

**Строка PR (Standard).**
- Строка 1:
  - точка непрочитанного или новых коммитов, 6 pt, коралл;
  - `StateBadge` — круг 22 pt, внутри *простой* глиф `pencil` / `xmark` / `checkmark` без второго кольца (`Utilities.swift:184-188`);
  - заголовок, до 2 строк;
  - справа фиксированные слоты: review-чип (≤132), CI-чип (44), комментарии (28), время (34, `monospacedDigit`).
- Строка 2: `repo#45` в `monoMeta`, автор (скрыт в «Created by me»), diffstat-бар 40×4 с числами, лейблы (2, затем «+N»).
- Состояния:
  - hover — `syHover`;
  - selected — нативное выделение `List`, в неактивном окне серое;
  - фокус — системное кольцо;
  - новое поступление — один insert glow sky.
- Compact: одна строка, данные второй строки уходят в тултип и метку VoiceOver.
- Контекстное меню: Open in New Window (⌥⌘O), Copy Link, Snooze ▸, Mark Done.
- **Порты:** WinUI `ListView` item templates; GTK `ListView` с классом `.compact`.

**Элемент сайдбара.**
- `List(selection: $app.section)` + `.tag` + `.badge(count)`.
- Цветные плитки сохраняем. Глиф 13 pt, размер плитки через `@ScaledMetric` (21→24).
- Брендовая полоса 3 pt остаётся оверлеем только у выделенной строки.
- Белый скос (`RootView.swift:527`) на macOS 26 — **[спросить владельца]**.
- Рейл:
  - микро-лейблы «PR», «ISS» вместо линий;
  - бейдж-капсула вне плитки;
  - Agents и Settings закреплены в `.safeAreaInset(edge: .bottom)`.
- **Windows:** NavigationView. **Linux:** `GtkListBox.navigation-sidebar`.

**Кнопки.** Одна prominent на скоуп.
- Primary с семантической заливкой: зелёная для merge/approve, `syRedFill` для request changes, `syCoralFill` + `syOnCoral` для агента.
- Состояния:
  - hover +4% L;
  - pressed −6% L + `PressScale` 0.96;
  - focus — системное кольцо;
  - disabled — 40% плюс *inline-причина*, никогда не молча.
- На 26: `.glassProminent` / `.glass`. На ≤15: `.borderedProminent` / `.bordered`.
- В каждом шите привязаны `.defaultAction` и `.cancelAction`.

**TabStrip.**
- Underline и его анимацию сохраняем (`TabStrip.swift:55-61`).
- Добавляем `.focusable()` и навигацию ←/→.
- Голые 1–6 переключают табы, когда фокус не в тексте (гейт как `ownsKeys`, `DiffTableView.swift:603`). ⌥⌘1–9 сохраняем.
- Бейджи как чипы: «1 failing».

**Тост.**
- Стеклянная капсула на 26, материал на ≤15.
- Принимает действие. Кликабелен всегда (сейчас `allowsHitTesting(app.toastIsError)`, `ShortLink.swift:73`).
- Длительность: 1.8 с без действия, 5 с с действием.
- **Windows:** InfoBar или TeachingTip. **Linux:** `adw::Toast` с `button-label`.

**Пустое состояние `PYEmptyState`.**
- Состав: `.hero`-логотип поверх двух волн `syHarborLine` и аврора из трёх пятен ≤8% (порт iOS `BrandBackdrop`), display-заголовок, одна строка `syMuted`, действие или keycap-чипы.
- Варианты: detail-empty, list-empty (без авроры, марка 48 pt, переиспользуем `ListEmptyNote`, `Utilities.swift:445`), first-run (чек-лист).
- **Windows:** то же поверх Mica. **Linux:** `adw::StatusPage` с марк-виджетом.

**Состояние ошибки** (`ErrorStateView`, `Utilities.swift:316-325`).
- Амбер-треугольник, display-заголовок с именем провайдера («Couldn't reach GitLab»), типизированная причина, Retry (primary) и «Open in browser».
- Ошибки загрузки показываются inline, не алертом.

### 4.6 Карта Liquid Glass

Всё за `#available(macOS 26, *)`, потому что пакет таргетит `.macOS(.v14)` (`Package.swift:6`). Хелперы iOS `pyGlass`, `pyGlassCapsule`, `pyGlassButton` (`ios/PullYardMobile/Glass.swift:5-20`) портируем как `Shared/Glass.swift` с тем же API.

| Поверхность | macOS 26 | macOS 14/15 | Windows 11 | Linux (GTK4/libadwaita) |
|---|---|---|---|---|
| Тулбар окна | системное стекло без `syBar`; на экранах PR — после спайка AppKit edge | непрозрачный `syBar` | Mica-тайтлбар (`MainWindow.xaml.cs:34-37` уже даёт Mica) | `adw::HeaderBar` |
| Сайдбар | стекло с тинтом `sySidebar` 30–40% (полноценно после NSV-спайка) | непрозрачный `sySidebar` | NavigationView pane на Mica | `navigation-sidebar`, непрозрачный |
| EdgeReveal peek (`Shared/EdgeReveal.swift:23`) | стекло | `.regularMaterial` | Acrylic | `.osd`, alpha .94 |
| Палитра команд | `.glassEffect(.regular, in: .rect(cornerRadius: 14))` | материал + обводка (как сейчас) | Acrylic flyout | сплошной popover |
| Тосты, pull-капсула, offline-капсула, short-link | капсулы в `GlassEffectContainer`, морфинг loading → done через `glassEffectID` | материал | Acrylic / InfoBar | `adw::Toast` |
| Свёрнутая плашка PR | стекло тулбара (после спайка), иначе `syBar` | `syBar` | Mica-строка CommandBar | под-бар HeaderBar, непрозрачный |
| Хедер панели Review / Agent run | только хедер стеклянный, содержимое непрозрачное | непрозрачно | Mica pane | `AdwOverlaySplitView`, непрозрачно |
| HUD `?`, коучмарки FixTour, оверлей drop в чате | стекло | материал | Acrylic | `.osd` / `Gtk.ShortcutsWindow` |
| Кнопки шитов | `.glass` / `.glassProminent` | bordered | ContentDialog | `adw::AlertDialog` appearances |

**Всегда непрозрачно на всех платформах:**
- diff и гаттер;
- список файлов;
- строки PR, issue и уведомлений;
- разговор (WKWebView) и markdown;
- логи чеков;
- readiness-полоса и баннеры;
- чипы;
- поля ввода внутри стеклянных баров (`syRaised`);
- транскрипт агента и терминал;
- формы настроек.

---

## 5. Спеки по экранам

### 5.1 Главное окно

- **Брейкпоинты:**

| Ширина окна | Сайдбар | Список | Дополнительно |
|---|---|---|---|
| < 1180 | рейл 60 | 280–320 | |
| ≥ 1180 | 220 | 360 | |
| ≥ 1600 | 220 | до 440 | правая панель Review / Agent вместо пустоты (`main-large-light.png` сейчас идентичен laptop) |

- **Заголовок окна** вычисляется из `frontRoute`: при PR — `title = pr.title`, `subtitle = "owner/repo #N · Review requests"`.
- **Тулбар PR**, слева направо, с `ToolbarSpacer(.fixed)` между группами на 26:
  1. ‹ ›
  2. RefreshPill
  3. Review ▾ (n)
  4. Fix with agent ▾ (`.glass`, тинт коралл, лейбл `syCoralInk`; на ≤15 — `syCoralFill` + `syOnCoral`)
  5. Merge: `glassProminent` зелёный, когда готов; `.glass` при блокерах; скрыт при `!canMerge`. Для этого `canMerge` получает вход `blocked` из readiness.
  6. Safari + More
- **Меню «Pull Request»** (`CommandMenu` на `@FocusedValue`):
  - Write Review… ⇧⌘R
  - Approve ⇧⌘A
  - Request Changes…
  - Merge… ⇧⌘M
  - Fix with Agent ▸ ⇧⌘F
  - Re-run Failed Checks
  - Mark All Files Viewed
  - Open in Browser ⇧⌘O
  - Copy Link
  - Copy Checkout Command
  - Next / Previous in Queue ⌥⌘↓ / ⌥⌘↑

  Меню заменяет `.opacity(0)`-кнопки (`PRDetailView.swift:103-118`). Рядом с `ToolbarCommands()` (`PullYardApp.swift:57`) добавляем `SidebarCommands()`.
- **Пустая деталь:** `PYEmptyState`, заголовок «Nothing docked yet», keycaps ⌘L ⌘K ⌘/. В Фазе 2 ниже появляются карточки «Next up»: review requests на мне, мои PR с блокерами, недавние (`recentRoutes`). Заменяет `RootView.swift:186-190`.
- **Motion:** route swap — fade `Dur.base`; EdgeReveal без изменений, на 26 — стеклянный.

### 5.2 Списки и инбокс

- **Хедер колонки.** Open/Closed/All в `syAccentFill` и меню сортировки с подписью «Updated ↓» вместо голой иконки (`SearchListView.swift:339-351`). Слияние полосы 36 pt в строку 28 pt — **[спросить владельца]**.
- **Плейсхолдер** «Filter this list…». Если фильтр пуст по результатам, показываем строку «Search all of GitHub for '…' (⌘K)».
- **Review requests** разбит на секции `Section(isExpanded:)`: Your turn / Waiting on author / Team / Snoozed. Для «Re-review» нужен последний ревью-коммит зрителя в `PRItem`.
- **Пустой «Your turn»:** hero-логотип рисуется один раз, «Nothing needs you».
- **Клавиши:**
  - j/k — как ↑/↓, открытие с дебаунсом 150 мс;
  - o / ↩ — открыть;
  - e — Done;
  - s — snooze;
  - / — фильтр;
  - r — refresh.

  Всё только когда фокус не в тексте.
- **Уведомления:**
  - read-on-open (↩ / двойной клик) вместо read-on-select (`NotificationsView.swift:93-97`) — **[спросить владельца]**, меняется поведение;
  - hover-кнопка «Done» с отложенной отправкой 5 с и Undo;
  - группировка по PR;
  - `.syIcon(11)` вместо `.system(size: 11)`.

### 5.3 PR detail

- **Полный хедер** (Conversation, прокрутка в начале):
  - заголовок в `prTitle`, `#N` в `syMuted`;
  - state pill: open — зелёный, draft — slate, merged — violet;
  - мета: автор, base ← head, diffstat.
- **Readiness-полоса.** Одна строка на блокер, у каждой свой глагол:

| Блокер | Действие |
|---|---|
| Конфликты | «Resolve conflicts with agent» (`syCoralFill`, единственная коралловая заливка) + «View conflicts» (popover, а не скролл) |
| CI | «Fix checks with agent» · «Re-run failed» |
| Ветка отстаёт | «Update branch» (включить в `canPerform`, `PRDetailView.swift:665`) |
| Draft | «Ready for review» |

  Сверху ряд микро-чипов Reviews · Checks · Conflicts · Rules. «1 failing · 0 passing» вместо «✕1 ✓0», нулевой ✓ не рисуем.
  - Слияние `CIFailureBanner` и строки конфликтов в одну полосу — **[спросить владельца]**.
  - Аддитивный фолбэк, если владелец против: баннеры остаются, но получают тот же компонент строки и intent-глаголы.
- **Свёрнутая плашка 36 pt.** На Files, Checks и Commits или при скролле больше 8 pt:
  `#45 · title · ● Open · [✕ 1 check] [⚠ conflicts] · Viewed 3/17 ▬ · Review (3) · Merge`.
  - Чипы открывают свою строку блокера как popover.
  - Схлопывание — `Spring.snappy`.
  - Первая строка кода смещается с ~333 pt до ~150 pt, то есть примерно +60% видимого кода на ноутбуке.
- **Агент рядом с PR.** Запуск из PR оставляет PR на экране, в плашке появляется чип «Fix running · 2m» (`WakeLoader` + коралл). ⌥-клик ведёт в раздел Agents, как сейчас (`ClaudeLaunchControls.swift:9`). В Фазе 3 сессия стримится в правой панели.
- **Завершение действий:**
  - После merge шит закрывается сразу. Pill морфится Open → Merged через `contentTransition` (`Dur.base`). Тост: мини-марка, корпус сдвигается на 16 pt со следом `syWake` (≤700 мс), текст «Merged #45 into main · Restore branch · Next →».
  - После approve: штамп ✓ (`Spring.bouncy`), тост «Approved #45 · Next review request ⌥⌘↓».
  - Начиная с 3-го merge за сессию — только морф pill.
  - Reduce Motion: финальный кадр плюс тост.

### 5.4 Files / diff (всё непрозрачно)

- **Гаттер:**
  - фон `sySunken` @0.6;
  - полоса изменения 3 pt: зелёная, красная или коралловая для строк с комментами;
  - знак diff в отдельной тонированной колонке;
  - «+» комментария только на hover или фокусе строки: квадрат 14 pt `syCoralFill` с глифом `syOnCoral`. Убирает постоянный `" +"` из `DiffTableView.swift:206`, `:233`; кликабельная область остаётся прежней;
  - номера строк в `syGutter` v2.
- **Wrap** выключен по умолчанию только для новых установок; у существующих пользователей значение `@AppStorage` сохраняется. Пер-файловый Wrap в меню ⋯ хедера файла.
- **`reviewBar`** (`FilesTab.swift:136-190`) — 28 pt:
  - «File ↑↓» на `chevron.up` / `chevron.down`;
  - «Change ↑↓» с текстом вместо `arrow.up.to.line`;
  - Wrap;
  - Unified/Split.

  При свёрнутом хедере контролы вливаются в плашку.
- **Панель файлов:**
  - ресайз 200–420 вместо фиксированных 260 (`FilesTab.swift:21`), на внутреннем `ColumnResizeHandle`;
  - Tree/Flat (⌥T) со сжатием одиночных папок;
  - строки 24 pt: статус-буква · имя · `+24 −6` · 💬 n · ✓ viewed;
  - чип «Owned by me»;
  - прогресс viewed — коралловая полоса на треке `sySunken` и число.
- **Intraline-подсветка** в `DiffStyle.attributed` (`DiffTableView.swift:112`). Условия: длина строки < 500, общих токенов ≥40%.
- **Hunk-строки:** «↑ 20 · ↓ 20 · All».
- **Диапазоны и suggestions.** Shift-клик или drag в гаттере выбирает диапазон; «Suggest change» (⌘G). Основной кнопкой становится «Add to review», под ⌘↩ (`FilesTab.swift:763-769`).
- **Линейка обзора** на скроллере с тиками add/del/comment. Миникарту не делаем.
- **Accessibility:** у строк `DiffTable` должны быть a11y-метки «line 53, added: …» и видимое кольцо фокуса строки.

### 5.5 Agents

- Структуру сохраняем: `ClaudeTabBar`, логику ширины инспектора, градиенты Chat (`ChatComposer.swift`, `ChatViews.swift`), `DiveLogo`, кольцо «done».
- Единый «working» — `WakeLoader` (`ClaudeViews.swift:538`, `ClaudeStatus.swift:168` и CALayer-спиннер).
- Композер на 26 — стеклянный бар, поле внутри непрозрачное `syRaised`.
- Пустое состояние: «No agent sessions yet» и hero-логотип.
- Переименования строк (см. Фазу 1). Иконка `terminal.fill` → «ship + spark» — **[спросить владельца]**.
- Отдельный визуальный аудит транскрипта, инспектора и таб-бара — Фаза 3, нужны неразмытые скриншоты.

### 5.6 Шит Merge

- Хедер: мини-марка 20 pt, корпус зелёный (чисто) или амбер (блокеры).
- Встроенный живой `MergeRequirementsList`, обновляется по `onLiveTick`.
- Метод выбирается сегментированным контролом с символами.
- **Primary по состоянию:**

| Состояние | Primary | Secondary |
|---|---|---|
| Чисто | «Merge» `syGreenFill`, `.defaultAction` | — |
| Только ожидание чеков/ревью | «Merge when ready» (повышение существующей «Enable auto-merge», `PRSheets.swift:173-178`) | «Merge anyway» |
| Конфликт / отстаёт | глагол фикса («Resolve conflicts with agent» / «Update branch») | «Merge anyway» — красная обводка, без заливки |

- Ошибка после submit показывается inline-баннером в шите, а не алертом.
- **Windows:** ContentDialog. **Linux:** `adw::AlertDialog` с extra-child.

### 5.7 Шит Review (шаг 1) → панель Review (шаг 2)

**Шаг 1, шит:**
- Сегменты Comment | Approve | Request changes. Последний вердикт запоминается для репо.
- Submit меняет лейбл и цвет по вердикту: «Approve» — зелёный, «Request changes» — `syRedFill`, «Comment» — `syAccentFill`.
- Inline-причина для неактивного Submit: «Add a summary or an inline comment».
- Список ожидающих комментариев (file:line, клик — переход) вместо счётчика (`PRSheets.swift:94-96`).

**Шаг 2, правая панель 320 pt** (`Dur.slow`):
- Сверху вниз:
  1. «Review #45» (стеклянный хедер на 26)
  2. «12/17 viewed · 2 unresolved»
  3. комменты по файлам
  4. сегменты вердикта
  5. summary
  6. Submit ⌘↩
- Агентские черновики помечены коралловым «Agent draft» с Accept / Edit / Discard; автоматически ничего не постится.
- Панель открывается только вместе с focus mode (сайдбар и список сворачиваются в EdgeReveal), иначе при 1380 pt на код остаётся ~220 pt.
- Шит остаётся доступен из меню.

### 5.8 Настройки

- `.tint(Color.syAccent)` на всю сцену Settings.
- `.formStyle(.grouped)`.
- About-блок в General: `.hero`-логотип рисуется один раз, вордмарк New York, версия.
- Заголовок «Claude Code» → «Agents» (`SettingsView.swift:219`).
- Новые контролы: «List density: Compact / Standard / Roomy» и панель «Keyboard» из того же реестра команд.

### 5.9 Логин и онбординг

- Хореографию сохраняем. Любой клик или клавиша мгновенно доводят её до финального кадра (cut, без пропуска кадров).
- Hero-логотип и вордмарк New York.
- Один primary «Sign in with GitHub» в `syCoralFill` / `syOnCoral`, как CTA сайта. Остальные способы под «Other ways to sign in» — **[спросить владельца]**. Аддитивный вариант: все карточки остаются, у первой просто primary-вес.
- `.inline`-лоадер вместо `LoginView.swift:162`.
- Первый запуск: в пустой детали карточка-чек-лист из трёх пунктов (уведомления, подключить Agents, Jira опционально), без модального визарда.

### 5.10 Палитра команд

- Стеклянная панель на 26; при Reduce Transparency — непрозрачная.
- Секции: «This pull request» (eyebrow) → Go → Actions.
- PR-глаголы с keycaps: Approve, Request changes, Write review, Merge…, Fix with agent ▸, Re-run failed, Check out, Copy branch, Toggle split, Next unviewed file, Mark all viewed, Snooze.
- Агентские глаголы с коралловым глифом.
- Один реестр команд кормит палитру, меню «Pull Request» и HUD `?`.

### 5.11 Menubar

- `.inline`-лоадер вместо `MenuBarView.swift:36`.
- Строки получают CI- и review-чипы (`MenuBarView.swift:149-181`).
- Ссылку «Buy me a pizza» (`:120`) не трогаем.
- **Windows:** tray flyout. **Linux:** StatusNotifier, если он есть.

---

## 6. Фазированный план

Размер: **S** — до ~2 дней, **M** — ~1 неделя, **L** — больше недели или нужен спайк. Колонка «A/С»: аддитивно или нужно согласие владельца.

### Фаза 1 — быстрые победы (S), максимальный эффект на восприятие

| # | Что | Файлы | Размер | Windows / Linux | A/С |
|---|---|---|---|---|---|
| 1.1 | **Правда в тулбаре:** одна `RefreshPill` с `.fixedSize()`, без двойного ↻ и лишнего спиннера, типизированные ошибки вместо «Offline» | `Shared/Refresh.swift:24-60`, `:132-141`; `Features/PR/PRDetailView.swift:228-242` | S | CommandBar status / HeaderBar widget; `NetworkInformation` / `GNetworkMonitor` | A |
| 1.2 | **Заголовок окна = PR** (title + subtitle из `frontRoute`), кнопки ‹ › | `App/RootView.swift`, `Features/Lists/SearchListView.swift:407-408` | S | заголовок окна / `adw::WindowTitle` | A |
| 1.3 | **Merge при блокерах визуально приглушён** (вход `blocked`), `ToolbarSpacer` между Fix и Merge | `PRDetailView.swift:222-224`, `:266-279` | S | accent только при ready / `.suggested-action` только при ready | A |
| 1.4 | **`PYLoader` `.inline` / `.block`**, единая cubic-кривая, минимум 400 мс; замена всех 25 неопределённых `ProgressView` | `Shared/LogoLoader.swift`, `Shared/Utilities.swift:328-340`, 19 файлов из grep | S–M | `LogoLoader.cs` StrokeDashOffset; `logo.rs` dash | A |
| 1.5 | **Гаттер diff:** «+» только на hover, коралл; `syGutter` v2; полоса изменения 3 pt; знак в своей колонке | `Shared/DiffTableView.swift:204-234`, `Shared/Theme.swift:106` | S | то же правило в WinUI/GTK-рендерерах | A (контраст — твик) |
| 1.6 | **Статус-чипы:** CI-чип вместо голого ✕, review-чип текстом, «1 failing · 0 passing», `StateBadge` без двойного кольца | `Shared/Utilities.swift:180-192`, `:236-242`, `:274-280`; `SearchListView.swift:578-582`, `:615-620`; `PRDetailView.swift:694-702` | S | pill-компонент с теми же токенами | A |
| 1.7 | **Брендовая пустая деталь:** `PYEmptyState` с hero-логотипом (stroke → fill, 2 цикла bob, стоп) + линия воды + keycaps | `App/RootView.swift:186-190` | S | Mica + тот же арт / `adw::StatusPage` | A |
| 1.8 | **Токены контраста:** `syDim`, `syLink`, `syAccentFill` для сегмента «Open», `syCoralFill` / `syOnCoral` / `syCoralInk`; кнопка в CI-баннере на `syCoralFill` | `Shared/Theme.swift:76-131`, `Features/ClaudeFix/CIFixBanner.swift:52-55`, `PRSheets.swift:405-406` | S | ключи в `Brand.xaml` / `theme.rs` | A (твики значений сообщить) |
| 1.9 | **Нейминг:** «agent session» / «Agents» в `ClaudeViews.swift:287`, `StackTab.swift:802`, `:911`, `CIFixBanner.swift:71`, `SettingsView.swift:219`, `AccountSwitcher.swift:48` | перечисленные | S | те же строки в портах | A |
| 1.10 | **Шит Review, шаг 1:** сегменты, лейбл и цвет Submit по вердикту, inline-причина, список pending; Merge: `.defaultAction` при clean | `Features/PR/PRSheets.swift:78-126`, `:150-195` | S | ContentDialog / `adw::AlertDialog` | A |
| 1.11 | **Settings `.tint`** и About-блок | `App/SettingsView.swift` | S | accent в ресурсах / CSS | A |
| 1.12 | **Refresh там, где его нет:** Jira, RepoCode | `Features/Jira/JiraViews.swift:116`, `Features/Repos/RepoCodeView.swift` | S | то же | A |
| 1.13 | **Motion v2:** слайд строк 8 pt, каскад только при первой загрузке и максимум 8 строк, `@Environment` для Reduce Motion | `Shared/Motion.swift`, `Shared/RowAppear.swift:105` | S | `UISettings.AnimationsEnabled` / `gtk-enable-animations` | A |
| 1.14 | **Символы навигации diff:** «File» / «Change» вместо `arrow.up.to.line`; `reviewBar` 28 pt | `Features/PR/FilesTab.swift:136-190` | S | Fluent / Adwaita symbolic | A |

### Фаза 2 — M

| # | Что | Файлы | Размер | Windows / Linux | A/С |
|---|---|---|---|---|---|
| 2.1 | **Тосты с действием и Undo:** кликабельные, 5 с, отложенный коммит для Done и удаления ветки; моменты merge и approve ≤700 мс | `Shared/ShortLink.swift:60-75`, `App/AppModel.swift:905-915`, `Features/PR/PRDetailModel.swift:729-786` | M | InfoBar с кнопкой / `adw::Toast` button | A |
| 2.2 | **Readiness-полоса** с intent-глаголами, микро-чипы, `canPerform` для update/ready, «View conflicts» как popover; «Fix with agent ▾» в тулбаре: Review comments · Failing checks · Conflicts | `PRDetailView.swift:58-62`, `:595-707`, `:266-271`; `CIFixBanner.swift` | M | WinUI InfoBar + SplitButton / `Adw.Banner` + `GtkMenuButton` | слияние баннеров и split-кнопка — **С** |
| 2.3 | **Шит Merge как чек-лист:** встроенный живой `MergeRequirementsList`, primary по состоянию | `PRSheets.swift:150-195`, `Features/PR/MergeRequirementsList.swift` | M | то же | A |
| 2.4 | **Свёрнутая плашка PR** (36 pt, непрозрачная на всех ОС до спайка) | `PRDetailView.swift`, `FilesTab.swift` | M | строка CommandBar / под-бар HeaderBar | A |
| 2.5 | **Меню «Pull Request»** на `@FocusedValue`, удаление `.opacity(0)`-хака; контекстные глаголы в палитре; HUD `?` из общего реестра | `App/PullYardApp.swift:56-116`, `PRDetailView.swift:103-118`, `Features/Palette/CommandPalette.swift:495-560` | M | `KeyboardAccelerator` + MenuBar / `GMenu` + `Gtk.ShortcutsWindow` | A |
| 2.6 | **Сайдбар `List(selection:)`** + `.badge`, `@ScaledMetric`-плитки, рейл с микро-лейблами и закреплёнными Agents/Settings | `App/RootView.swift:290-528` | M | NavigationView / `GtkListBox.navigation-sidebar` | A; скос на 26 — **С** |
| 2.7 | **Плотность Compact / Standard / Roomy**, новая строка PR, j/k, клавиши действий | `SearchListView.swift:555-620`, `Shared/Theme.swift` (Density), `SettingsView.swift` | M | ListView templates / `.compact` CSS | A; дефолт для новых — сообщить; полоса хедера — **С** |
| 2.8 | **Уведомления:** hover Done, read-on-open, группировка по PR | `Features/Notifications/NotificationsView.swift` | M | то же | read-on-open — **С** |
| 2.9 | **Стекло на плавающем слое (26):** палитра, тосты, pull-капсула, EdgeReveal, HUD, коучмарки; порт `Shared/Glass.swift`; учёт Reduce Transparency | `CommandPalette.swift:174-181`, `ShortLink.swift`, `Refresh.swift`, `EdgeReveal.swift:23`, `FixTour.swift` | M | Acrylic / `.osd` | A |
| 2.10 | **Спайк: тулбар без краски над AppKit diff и WKWebView** (edge effect / `NSScrollPocket` / хост-оверлей); при успехе снимаем `syBar` на 26 везде | `App/RootView.swift:532-536`, `DiffTableView.swift`, `Shared/HTMLView.swift` | M | Mica-тайтлбар уже есть / HeaderBar | A |
| 2.11 | **Files:** ресайз, Tree/Flat, прогресс viewed, Owned by me, no-wrap для новых установок | `FilesTab.swift:12-22`, `:390-420`, `Shared/DiffLayout.swift` | M | TreeView / `GtkTreeListModel` | A |
| 2.12 | **Increase Contrast** + a11y строк `DiffTable` | `Theme.swift:62-67`, `DiffTableView.swift` | M | `HighContrast` / `is_high_contrast()` | A |
| 2.13 | **«Next up»** в пустой детали + чек-лист первого запуска; fast-forward сплэша и логина | `RootView.swift`, `SplashView.swift`, `Auth/LoginView.swift` | M | карточки / `adw::StatusPage` | A; сворачивание карточек входа — **С** |
| 2.14 | **Агент рядом с PR:** чип «Fix running» в плашке, без переключения раздела | `Features/ClaudeFix/ClaudeLaunchControls.swift:9`, `CIFixBanner.swift:46-49` | M | то же | A |

### Фаза 3 — L

| # | Что | Файлы | Размер | Windows / Linux | A/С |
|---|---|---|---|---|---|
| 3.1 | **Спайк `NavigationSplitView`** за флагом. Критерии: рейл, EdgeReveal, сохранение ширин, toolbars по колонкам. При успехе — стеклянный сайдбар с тинтом 30–40% | `App/RootView.swift:100-262` | L | WinUI NavigationView / уже `adw::OverlaySplitView` + `adw::Breakpoint` 1180sp | A |
| 3.2 | **Очередь «Your turn»:** секции, snooze, «new since you looked», размер XS–XL (только в Compact) | `API/Queries.swift`, `SearchListView.swift`, `App/AppModel.swift` | L | grouped ListView + InfoBadge / GTK sections | A |
| 3.3 | **Правая панель Review + Agent run** (`.inspector`), только с focus mode; агентские черновики | `PRDetailView.swift`, `PRDetailModel.swift` | L | SplitView pane / `AdwOverlaySplitView` | A |
| 3.4 | **Intraline, раскрытие контекста, диапазоны, suggestions**, серверный pending review | `DiffTableView.swift:112`, `Features/PR/Diff.swift:50-54`, `FilesTab.swift` | L | общий алгоритм как спека для C# / Rust | A |
| 3.5 | **Мульти-окно** `WindowGroup(for: Route.self)`, ⌥⌘O; рефакторинг `AppModel` на состояние per-window | `App/PullYardApp.swift:44-58`, `AppModel.swift` | L | `AppWindow` / `adw::ApplicationWindow` | A |
| 3.6 | **Checks tab:** группировка по workflow, Required, лог-эксцерпт inline, аннотации в гаттере | `PRDetailView.swift:860-910`, `Features/ClaudeFix/CILogExcerpt.swift` | M–L | то же | A |
| 3.7 | **Стеки:** действия (update stack, merge bottom & retarget); донатный `NSAlert` → inline-карточка | `Features/PR/StackTab.swift:131-212` | M–L | inline progress / `adw::Toast` | алерт — **С** |
| 3.8 | **Покрытие пробелов:** Issue detail, Commits/`CommitDetailView`, Jira-строки, GitLab/Gitea-строки (`ForgeListView.swift:303-332`), Update window, Unlock, account switcher, Fix/Resolve-шиты, визуальный аудит Agents | соответствующие | L | то же | A |
| 3.9 | **`brand.json` → генерация** `Theme.swift`, `AppTheme.swift`, `Palette.cs`, `theme.rs`; iOS-фикс `accentFill` | новые генераторы | M | основная цель | A; hex корпуса логотипа — **С** |

**Паритет портов.** Каждый пункт Фазы 1 в macOS-PR сопровождается тикетом «port: Windows/Linux» с той же спекой токенов. Фаза 1 портируется целиком до старта Фазы 3. Liquid Glass-пункты на Windows и Linux деградируют до Mica/Acrylic и непрозрачных или `.osd`-поверхностей соответственно.

---

## 7. Чего сознательно НЕ делаем

- **Стекло на плотных поверхностях:** diff, гаттер, список файлов, строки списков, разговор, логи, баннеры, чипы, транскрипт. Рефракция под моноширинным текстом убивает читаемость и FPS скролла.
- **Плавающий glass-HUD над diff и нижний review-док.** Они закрывают код и громоздятся поверх уже существующего композера (`PRDetailView.swift:766`).
- **Коралл как универсальный primary и «коралловый отблеск» на Merge.** Merge и Approve остаются зелёными: это ментальная модель GitHub.
- **Коралловый underline TabStrip, коралловые eyebrow в сайдбаре, serif в заголовках колонок и окна.** Всё это размывает смысл коралла и ломает нативный хром.
- **Корабль как иллюстрация ошибки.** Бренд не должен означать сбой.
- **Бесконечный bob героя, конфетти, звуки по умолчанию, празднование длиннее 700 мс или блокирующее ввод.**
- **Смена кривой бренда на 0.16,1,0.3,1.** Разница незаметна, а churn будет.
- **Разрушение брендовых элементов.** Не удаляем pull-to-refresh, EdgeReveal, row-appear, `WakeLoader`, underline-анимацию TabStrip, градиенты Agents, цветные плитки сайдбара, ссылку на пиццу.
- **Нативные вкладки окна вместо таб-бара Agents.** Они не умеют показывать глифы состояния.
- **Миникарта diff** (только линейка обзора), **автопостинг AI-ревью и AI-саммари-баннер** на каждом PR.
- **Переписывание WKWebView-разговора в нативные вьюхи** сейчас. Он работает и концептуально общий с WebView2 на Windows.
- **Автоскрытие футера свежести.** Противоречит правилу «refresh везде».
- **Отдельный j/k-курсор без открытия PR** до рефакторинга привязки выделения.
- **Повышение минимальной macOS** без решения владельца (см. вопрос 1).
- **Скачиваемые шрифты.**

---

## 8. Вопросы владельцу

1. **Минимальная версия macOS.** Остаёмся на 14 с `#available(macOS 26, *)` для стекла или поднимаем до 15? `containerBackground(for: .window)` требует 15, а 14 удваивает стоимость фолбэков.
2. **Сайдбар на macOS 26.** Оставить плитки как есть, убрать только белый скос (`RootView.swift:527`) или перейти на тонированные символы без плиток? И можно ли заменить иконку Agents `terminal.fill` на «ship + spark»?
3. **Консолидация агента и блокеров.** Можно ли объединить `CIFailureBanner` и строку конфликтов в одну readiness-полосу и превратить «Fix with agent» в тулбаре в split-кнопку (Review comments / Failing checks / Conflicts)? Если нет, делаем аддитивный вариант: баннеры остаются, получают intent-глаголы.
4. **Коралл и список.** Принимаете «коралл = действуешь ты или твой агент + CTA логина»? Из этого следует перекраска папки «My PRs by project» (`RootView.swift:349`). Можно ли новым установкам по умолчанию давать 2-строчные строки и свернуть полосу Open/Closed/All (`SearchListView.swift:332-355`) в строку 28 pt?
5. **Поведение и тексты.**
   - Уведомления помечать прочитанными при открытии, а не при выделении стрелкой? «Done» отправлять с задержкой 5 с ради Undo?
   - Спрятать CLI/PAT/OAuth под «Other ways to sign in»?
   - Донатный алерт графа стеков (`StackTab.swift:189-211`) превратить в inline-карточку?
   - Оставить ли как есть упоминания «Claude Code» в строках зависимостей и в юридическом тексте (`SettingsView.swift:429`, `ClaudeAccount.swift:283`, `ClaudeAccounts.swift:322`, `:367`)?
