# PullYard для iPhone: итоговый план совета

## Вердикт

У приложения правильный скелет: очередь PR, Inbox, детальный экран PR с ревью, поиск. Но почти каждый сценарий ломается в решающий момент. Поэтому оно и ощущается сырым.
- **Офлайн-старт.** На холодном старте без сети пользователь видит экран входа, хотя кэш есть.
- **Inbox.** Открытая нотификация удаляет свою строку и выкидывает пользователя обратно в список.
- **Композер.** Ответ, который не отправился, пропадает вместе с текстом.
- **Ложные состояния.** Ошибка загрузки выглядит как «всё чисто». Каждое автообновление сокращает очередь до 100 PR. На каждой дате написано «ago ago».
- **Сортировка без сигналов.** В строке нет CI, статуса ревью и автора, поэтому приходится открывать каждый PR.
- **Действия.** Код изменений не виден, Merge нет, «My PRs» никуда не ведёт.
- **Бренд.** Визуально это шаблон на системных цветах: спиннер вместо логотипа, белая кнопка на белом в тёмной теме.

«Полноценное» здесь значит четыре вещи:
1. Надёжный offline-first старт из кэша.
2. Очередь, по которой можно сортировать без открытия PR.
3. Закрытый цикл «увидел → посмотрел изменения → одобрил / смёржил → получил подтверждение → следующий PR».
4. Настоящий менеджер нотификаций GitHub, всё в бренде PullYard: палитра, анимированный логотип, motion.

ИИ-функций нет и не будет.

## Ключевые проблемы

### UX
- **Холодный старт игнорирует кэш.** `isSignedIn` требует `user != nil` (AppModel.swift:32). `user` не кэшируется (AppModel.swift:198-207). Bootstrap ждёт полного последовательного refresh (AppModel.swift:28, PullYardMobileApp.swift:17). Если `/user` падает офлайн, пользователь попадает на SignInView с уже подставленным токеном (SignInView.swift:51). [UX-1, ENG-1]
- **Открытая нотификация удаляет свою строку и закрывает экран.** Срабатывает `.task { markRead }` (InboxAndPullsView.swift:106), затем `removeAll` (AppModel.swift:169). View-based `NavigationLink` стоит внутри `ForEach` (InboxAndPullsView.swift:22-25). Если это последняя нотификация, весь List заменяется на ContentUnavailableView (InboxAndPullsView.swift:10-19), и pop гарантирован. Таймерный refresh с `all=false` (GitHubClient.swift:82) делает то же самое без markRead. На вкладке Pulls та же проблема: после ревью PR уходит из `review-requested:@me`, и детальный экран закрывается под пользователем. [UX-2, ENG-2, FN-D1]
- **Строки очереди без сигналов для сортировки.** Search-маппинг ставит `user: nil, draft: nil, merged: nil` (GitHubClient.swift:58). Поэтому «by @author» (InboxAndPullsView.swift:296) не рендерится, Draft и Merged не видны, CI и review decision отсутствуют. [UX-4, UI-5, FN-3, ENG-9]
- **Действия ревью спрятаны.** Approve и Request changes стоят только внизу Overview (PullRequestDetailView.swift:134-143) или в меню `ellipsis.circle` (PullRequestDetailView.swift:76-84). Они видны и на собственных PR, где GitHub отвечает 422. После отправки нет ни toast, ни haptic, ни «следующего PR». [UX-5, ENG-18, FN-13]
- **Около 150-170 pt фиксированного chrome над списком.** Два segmented picker и блок PROJECT (InboxAndPullsView.swift:131-147) не скроллятся, и pull-to-refresh начинается под ними. [UX-8, UI-16]
- **Refresh работает по-разному на каждом экране.** `.refreshable` есть только у заполненных списков (InboxAndPullsView.swift:33, 175). Пустые состояния не тянутся. В PR detail нет кнопки refresh в toolbar, у поиска нет никакого refresh. Повторный pull во время refresh молча ничего не делает (AppModel.swift:65, 110). [UX-7, FN-20]
- **Conversation — плоская лента.** Сортировка только по дате (PullRequestDetailView.swift:173-176). Ответы в inline-тредах разбросаны отдельными карточками. Обычные комментарии нельзя процитировать (`canReply: false`, строка 159). Лента открывается на самом старом сообщении. [UX-10, UX-D4]
- **Inbox и Needs review — два несвязанных списка одной работы.** Один и тот же элемент приходится разбирать дважды. [UX-D2]
- **Поиск затирает результаты на каждый символ** (SearchView.swift:52). `loadMore` берёт живой `query`, а не тот, по которому получены результаты (SearchView.swift:72). [UX-16, ENG-21]
- **Состояние теряется между запусками.** Сбрасываются tab, queue (AppModel.swift:9-10), фильтр статуса (`@State`, InboxAndPullsView.swift:115) и черновики. [UX-17]

### UI
- **Loader — системный спиннер.** Это вращающийся круг вокруг SF Symbol (AppTheme.swift:54-62, 73-76), а не прорисовка логотипа. Desktop-версия уже готова к порту: LogoLoader.swift, на TimelineView. [UI-1, ENG-24]
- **Палитры бренда нет.** accent = systemBlue, «coral» = systemRed, canvas = systemGroupedBackground (AppTheme.swift:4-13). [UI-2]
- **Главная кнопка входа белая на белом в тёмной теме.** `.foregroundStyle(.white)` на `MobileTheme.ink = .label` (SignInView.swift:36). Плитка логотипа (SignInView.swift:15-16) тоже. [UI-3]
- **«2 hours ago ago».** Это в 5 местах: InboxAndPullsView.swift:70, 298; SearchView.swift:34; PullRequestDetailView.swift:295, 312. [UI-4, ENG-3]
- **Неверные цвета состояний.** Closed зелёный (InboxAndPullsView.swift:295; PullRequestDetailView.swift:104), Merged синий (:104). В Search своя схема: closed серый (SearchView.swift:31). [UI-6, UX-15]
- **Markdown только inline.** Используется `.inlineOnlyPreservingWhitespace` (PullRequestDetailView.swift:377), размер 13 pt. Шаблоны PR, чеклисты, code fences и `<!-- -->` показываются сырым текстом. [UI-7, FN-10, ENG-23]
- **Шкалы типографики нет.** Размеры 9-39 pt, и все скейлятся `relativeTo: .body` (AppTheme.swift:29). Pill-текст 9 pt (InboxAndPullsView.swift:308), eyebrow 10 pt (PullRequestDetailView.swift:357, 365). У Approve белый текст на systemGreen, контраст около 2.2:1 (PullRequestDetailView.swift:137). [UI-11, UI-12]
- **Иконка с alpha-каналом и полями в стиле macOS** (AppIcon.png, `hasAlpha: yes`). Блокирует App Store. [UI-13]
- **Нет haptics, symbol effects и анимаций** (анимирован только loader, AppTheme.swift:75). [UI-20]
- **Шесть разных радиусов скругления (13-22) на соседних карточках.** [UI-22] **Непрозрачная полоса «Updated» над tab bar** (InboxAndPullsView.swift:46, 189). [UI-17]

### Функционал
- **Нет экрана изменённых файлов.** Метрики «+N −N, N files» не нажимаются (PullRequestDetailView.swift:117-121). Получается, что одобряют код вслепую. [UX-12, FN-1]
- **Нет Merge, auto-merge, Ready for review, Update branch, Close/Reopen.** В GitHubClient только comment, reply, review и markRead (GitHubClient.swift:84-93). Нет карточки merge readiness: `mergeable` — просто Bool, и его не опрашивают повторно (Models.swift:30, PullRequestDetailView.swift:105). [UX-11, FN-2, FN-4, ENG-17]
- **Checks неполные.** Commit statuses не загружаются (GitHubClient.swift:75-78). «Checks not loaded» показывается и до загрузки, и при нуле проверок (PullRequestDetailView.swift:200). Skipped считается passed (Models.swift:55). Нет re-run и логов. [FN-5, ENG-17]
- **Inbox умеет только unread.** «Done» на самом деле PATCH mark-read (InboxAndPullsView.swift:27, GitHubClient.swift:93). Нет настоящего Done, Mute, Mark all read и фильтров по причине. [UX-9, FN-7]
- **Нет resolve/unresolve тредов, реакций, событий timeline и «нового с прошлого визита».** [FN-6, FN-15, FN-16]
- **Пагинации нет.** Всё грузится одним запросом `per_page=100` (GitHubClient.swift:76-82). Комментарии идут от старых к новым, поэтому на длинных PR пропадают как раз последние. [ENG-11, FN-17]
- **Pending review, начатый на desktop или в вебе, ломает Approve с ошибкой 422.** В списке он висит пустой карточкой наверху. [FN-D2]
- **Нет deep links, фонового обновления, бейджа и уведомлений.** [FN-8, FN-18, UX-20] **Не-PR нотификации ведут в тупик** (InboxAndPullsView.swift:84, 96-104). [FN-19]
- **Вход только по classic PAT.** Device Flow заблокирован отсутствием client id. Fine-grained токен проходит вход, а потом ломает Inbox. [FN-9, ENG-15]

### Надёжность
- **Каждый refresh сокращает очередь до первой страницы** (AppModel.swift:82, 90, 116). Discovery запускается только из `.task(id: model.queue)` (InboxAndPullsView.swift:196-199). После входа она прерывается на `guard !isRefreshing` (AppModel.swift:110, 137). `pullCounts` не кэшируется. Сохранённый проект после этого показывает ложное «No pull requests here». [ENG-4, ENG-5, UX-D1]
- **Запросы очередей без `is:open`** (Models.swift:113). До 10 страниц search на каждый цикл при лимите search API 30 запросов в минуту. [ENG-10, UX-21]
- **Ошибки показываются модальным alert.** Отменённые запросы дают alert «cancelled» (AppModel.swift:117-119, 149-151; PullRequestDetailView.swift:221, 228). Фоновые ошибки склеиваются через `\n` в модальный alert на каждом тике таймера (AppModel.swift:104; PullYardMobileApp.swift:43). [ENG-6, ENG-7, UX-6]
- **Ошибка загрузки рисуется как «Inbox is clear» / «No reviews waiting»** (InboxAndPullsView.swift:8-18, 149-158). Для приложения сортировки это баг корректности. [ENG-8]
- **Неудачная отправка теряет текст.** ReplyComposer безусловно вызывает `dismiss()` (PullRequestDetailView.swift:406). Ошибка ревью уходит в alert за открытым sheet. Ответ на ответ отправляется на id самого ответа и получает 404/422 (строка 162). [UX-3, ENG-12, FN-11]
- **Keychain с `WhenUnlockedThisDeviceOnly`** (CredentialVault.swift:16). `read()` возвращает nil на любой OSStatus (строки 9-10). Prewarm до первой разблокировки выглядит как выход из аккаунта, а фоновые задачи не могут прочитать токен. После 401 мёртвый токен остаётся и подставляется в поле (AppModel.swift:185). [ENG-D2, ENG-15]
- **PR detail: загрузка «всё или ничего» и гонки.** Ошибка checks показывается как «Couldn't load pull request» (PullRequestDetailView.swift:95, 228). [ENG-16]
- **Нет ETag/304 и X-Poll-Interval** (GitHubClient.swift:31-32). Нет обновления по scenePhase. [ENG-13, ENG-20]
- **Разные id для одного PR.** В очереди это issue id, в detail — PR id (GitHubClient.swift:58 и PullRequestDetailView.swift:215-216). Optimistic-обновления и черновики, привязанные к id, промахнутся. [ENG-D1]
- **Архитектурный долг.**
  - Монолитный ObservableObject, синхронная запись кэша на main во время discovery (AppModel.swift:148).
  - Два ISO8601DateFormatter создаются на каждую дату (GitHubClient.swift:37-38).
  - Гонка данных на `scopes` (GitHubClient.swift:25, 47).
  - Нет тестов и нет seam для подмены сети.

  [ENG-22, ENG-D4, ENG-D5, ENG-25]
- **Готовность к релизу.** Нет PrivacyInfo.xcprivacy, нет MARKETING_VERSION, нет `ITSAppUsesNonExemptEncryption`. Генерируемый Info.plist не умеет массивы (project.yml:10-14). Per-account `@AppStorage` переживает выход из аккаунта. [FN-D6, ENG-D3, FN-D4]

## Спорные моменты

| Вопрос | Позиции | Решение |
|---|---|---|
| Данные для строк очереди | UX-4: REST search + lazy GraphQL hydrate для каждой страницы. FN-3/ENG: один GraphQL `search(type: ISSUE)` | **GraphQL search** с `is:open`, `first:50`, облегчённым `statusCheckRollup.state`, счётчиками других очередей через aliases. Снимает нагрузку с REST search-бюджета. В Фазе 1 декодируем поля REST search как дешёвый промежуточный шаг. |
| Pill состояния в строке | FN-3: всегда показывать. UI-5: только если отличается от фильтра | **Показывать только при отличии от активного фильтра**, а освободившееся место отдать под CI-глиф и review chip. |
| Шапка очереди | UX-8/UI-16: segmented. FN-12: 5+ очередей | **Горизонтальная лента chips со счётчиками** (UI-D6) в заголовке List, скроллится вместе со списком. Статус и проект — в одном Menu в toolbar, активные фильтры показываются снимаемыми chips. |
| Отдельная вкладка Mentions | UX-8: да. FN: нет | **Нет.** Mentions — это фильтр причины внутри Inbox. |
| Action bar при скролле | UI-8: прятать при скролле вниз. UX/FN/ENG: всегда видим | **Всегда видим, компактный.** На PR detail прячем tab bar (`.toolbar(.hidden, for: .tabBar)`), чтобы не было двух панелей (UI-D2). |
| Цвета кнопок | UX-5: coral. UI-8/UI-D7: роли по семантике | **Семантика UI-D7:** coral = бренд и внимание, red = ошибка или деструктивное действие (всегда со своим глифом, WCAG 1.4.1), green = approve, violet = merged/merge, accent = нейтральное primary. Approve — greenFill 2B7F50, Request changes — coral outline, Merge — violetFill 5E48C8, Ready — accentFill 1D70A6. |
| Markdown-рендерер | UI-7: свой обход PresentationIntent. FN-10: MarkdownUI или body_html. ENG: только нативный | **Нативный, без WKWebView.** Предпочтительно поддерживаемый GFM-рендерер, затемизированный токенами, плюс свои блоки: code card с copy, suggestion mini-diff, in-app #ref. Парсим один раз при загрузке, не на main actor. Зависимость утверждает владелец (вопрос 4). |
| Логотип в pull-to-refresh | UX-7/FN-20 считали, что `.refreshable` это умеет. UI-D1/ENG-D13: нельзя | **Оставляем `.refreshable` как механизм** (жест, a11y, async). Системный спиннер прячем через `UIRefreshControl.appearance().tintColor = .clear`. Сверху overlay-капсула: логотип прорисовывается пропорционально оттягиванию, на iOS 18 через `onScrollGeometryChange`, на iOS 17 через preference key. Во время работы — цикл loader, затем «Updated just now». |
| Полоса «Updated» внизу | UI-17: убрать. FN-20: оставить и сделать нажимаемой | **Свежесть переезжает наверх** (подзаголовок или footnote под large title), показывает относительный возраст, нажимается для refresh, при устаревании или офлайне становится amber. Внизу только временные элементы: офлайн-баннер, Undo/success toast, action bar. |
| Mark read при открытии | UX-2: пометить, но не удалять. FN-7: сделать настройкой | **По умолчанию помечаем прочитанным, но строку никогда не удаляем** (строка тускнеет). Удаление только по Done. Добавляется тумблер в Settings. |
| Approve свайпом | UX-14: trailing swipe. FN/UX: опасно, approval не отозвать | **Approve в свайп не ставим.** Он только в context menu с превью (CI, число файлов) и открывает compact composer. |
| Pending review | ENG-19: исключить. FN-D2: показывать | **Показываем.** Баннер «У вас незавершённое ревью · N комментариев», отправка через `/reviews/{id}/events`, Discard с подтверждением. |
| Хранение черновиков | ENG-12: UserDefaults. FN/ENG: Application Support | **Application Support (App Group) с file protection**, ключ PRKey + root comment id, очистка в signOut. Не UserDefaults и не Caches (LocalCache.swift:7 лежит в Caches, который iOS чистит). |
| Live search | UX-16: debounce 400 мс. ENG: лимит 30 запросов/мин | **Минимум 3 символа, debounce 500 мс и больше**, отмена задачи в полёте, ответы по устаревшему запросу отбрасываются. |
| Объём diff | FN-1: сразу полный, с line comments | **v1 (Фаза 3):** read-only список файлов и патч с прикреплёнными тредами. **v2 (Фаза 4):** line comments, pending review, синхронизация viewed. |
| Приоритет палитры | UI: critical. FN: high | **High**, но токены идут первыми в Фазе 2, до редизайна строк, панели и timeline. |
| Тесты | ENG-25: medium. FN: high | **Seam и фикстуры в Фазе 1**, до переписывания data-слоя на GraphQL. |
| Опровергнуто или уточнено | — | UI-19: AsyncImage использует `URLCache.shared`, то есть HTTP-кэш есть. Не хватает кэша декодированных изображений и параметра `s=` в URL аватара. UI-6: в Search closed серый, а не зелёный. ENG-5: на нынешнем холодном старте discovery в основном работает, ломается после входа, а после ENG-1 сломается на каждом запуске, поэтому они идут вместе. ENG-24/UI-1: путь из asset не нужен, геометрия уже есть в LogoLoader.swift:3-65, но у desktop-loader нет `title` и `tint`, их нужно добавить. FN-9/FN-5: scope `workflow` для re-run не нужен. FN-12: `review-requested:@me` уже включает команды, отдельная очередь с `read:org` не нужна. Для разделения используем `user-review-requested:@me`. |

## План

### Фаза 1: основа и баги (выпускается первой)

1. **Мелкие заметные исправления.**
   - Убрать `+ " ago"` в 5 местах, сделать общий `RelativeTime` на `TimelineView(.periodic(by: 60))`.
   - CTA и плитка входа: убрать белый текст на `ink`, поставить временную accent-заливку.
   - Один `PRDisplayState`: Open — зелёный, Draft — slate, Merged — violet, Closed — red; использовать в строке, detail и Search.
   - Контраст Approve.

   Файлы: InboxAndPullsView.swift, SearchView.swift, PullRequestDetailView.swift, SignInView.swift, AppTheme.swift. **S.** [UI-4, ENG-3, UI-3, UI-6, UX-15]

2. **Холодный старт из кэша.**
   - Кэшировать `GitHubUser`, `pullCounts`, `pullPages`, `lastUpdated`.
   - Signed in = есть токен; на SignInView переводит только `handleAuthFailure`.
   - `hasCompletedBootstrap` сразу после `loadCache()`.
   - Четыре bootstrap-запроса параллельно через `async let`.
   - Discovery принадлежит AppModel (Task-handle, отмена при sign-out и смене очереди); refresh во время refresh ждёт текущий, а не выходит.
   - Launch screen: цвет LaunchBackground и статичный логотип.

   Файлы: AppModel.swift, PullYardMobileApp.swift, LocalCache.swift, project.yml. **M.** [UX-1, ENG-1, ENG-5, UI-14]

3. **Keychain и сессия.**
   - Миграция на `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly` через `SecItemUpdate`.
   - `read()` возвращает Result: notFound / interactionNotAllowed / другое; при временной ошибке — состояние «locked», повтор на `.active`.
   - На 401 стирать Keychain и `token`, поле не заполнять.
   - Per-account настройки с ключом по login (`AccountPreferences`).

   Файлы: CredentialVault.swift, AppModel.swift, SignInView.swift, InboxAndPullsView.swift. **S.** [ENG-D2, ENG-15, FN-D4]

4. **Навигация по значениям и PRKey.**
   - `struct PRKey { repo; number }` как идентичность для роутинга, кэша, черновиков и overlay.
   - Все вкладки на `NavigationStack(path:)` с Codable `Route` и `AppRouter`; путь, tab, queue и фильтр в `@SceneStorage` / `@AppStorage`.
   - `GHNotification.unread` становится `var`; markRead только гасит строку, один раз, после загрузки detail.

   Файлы: Models.swift, PullYardMobileApp.swift, InboxAndPullsView.swift, SearchView.swift, AppModel.swift. **M.** [ENG-2, UX-2, FN-D1, ENG-D1, UX-17]

5. **Очереди: правильные запросы и refresh без обрезки.**
   - `is:pr is:open archived:false review-requested:@me` / `author:@me`; Closed и Merged лениво, отдельным запросом; добавить фильтр Merged.
   - Refresh делает upsert по PRKey вместо замены на первую страницу.
   - Фильтр статуса сохраняется для каждой очереди.
   - Ложное пустое состояние проекта: пока идёт discovery — «Ищем в остальных проектах…» с loader; финальный empty только после конца; кнопка «Show all projects».

   Файлы: Models.swift, GitHubClient.swift, AppModel.swift, InboxAndPullsView.swift. **M.** [ENG-4, ENG-10, UX-21, UX-D1, UX-15]

6. **Модель ошибок и состояний.**
   - `Error.isCancellation`; отмена нигде не попадает в UI.
   - `LoadState` (idle / loading / loaded(Date) / failed) отдельно для каждой очереди, Inbox и секции PR.
   - `FeedbackCenter`: верхний баннер (офлайн, rate limited до HH:MM, auth) и нижняя очередь toast (success, undo, error) с haptic и VoiceOver-announcement, дедупликация по ключу.
   - Убрать `.mobileError` для фоновой работы; разделить error state и empty state.
   - Маппинг ошибок: `errors[].message` у 422, `.notFound` с контекстом, типизированный `.offline`, сравнение `X-Accepted-OAuth-Scopes`.

   Файлы: AppModel.swift, AppTheme.swift, GitHubClient.swift, InboxAndPullsView.swift, PullRequestDetailView.swift, SearchView.swift, новый Feedback.swift. **M.** [ENG-6, ENG-7, ENG-8, ENG-14, UX-6, UI-D4]

7. **Композеры не теряют текст.**
   - `send` бросает ошибку; inline-баннер с Retry внутри sheet; dismiss только при успехе.
   - `interactiveDismissDisabled(!draft.isEmpty)` и диалог «Discard draft?» с «Keep editing» по умолчанию.
   - Reply на `inReplyToId ?? id`.
   - Черновики в Application Support по PRKey и треду.
   - Pending review: баннер, Submit через `/reviews/{id}/events`, Discard.

   Файлы: PullRequestDetailView.swift, AppModel.swift, GitHubClient.swift, Models.swift, новый DraftStore.swift. **M.** [UX-3, ENG-12, FN-11, FN-D2]

8. **Роли в ревью и данные search.**
   - Декодировать `user`, `draft`, `created_at`, `comments`, `labels`, `pull_request.merged_at` в SearchItem.
   - Прятать Approve и Request changes, если `pull.user.login` совпадает с `model.user.login` без учёта регистра.

   Файлы: Models.swift, GitHubClient.swift, PullRequestDetailView.swift. **S.** [ENG-9, ENG-18, FN-13]

9. **Полнота данных PR.**
   - Общий `paginated<T>` по `Link rel=next` с лимитом страниц; для conversation сначала новые и «Load earlier».
   - Commit statuses `/commits/{sha}/status` сливаются с check-runs.
   - «No checks reported» вместо «not loaded»; skipped не считается passed.
   - Повторный запрос при `mergeable == nil` через ~2 с.

   Файлы: GitHubClient.swift, Models.swift, PullRequestDetailView.swift. **M.** [ENG-11, FN-17, ENG-17, FN-5]

10. **Экономное обновление.**
    - Refresh на `scenePhase == .active`, если данным больше 60 с.
    - Таймер только для видимой вкладки.
    - ETag / If-None-Match / If-Modified-Since по образцу desktop `restPolled` (Sources/PullYard/API/GitHubAPI.swift:259-300).
    - Учитывать `X-Poll-Interval`; `rateLimitedUntil` останавливает сетевые запросы.

    Файлы: GitHubClient.swift, AppModel.swift, PullYardMobileApp.swift. **M.** [ENG-20, ENG-13]

11. **Тестовый seam.**
    - `protocol GitHubAPI`, `protocol CredentialStore`, инъекция в AppModel.
    - Target `PullYardMobileTests` в project.yml.
    - Фикстуры: search, pulls, reviews, notifications, 401, 403 rate-limit, 422.
    - Тесты: merge при refresh, фильтр отмены, маппинг ошибок, старт из кэша.
    - Preview-фикстуры на все состояния экранов.

    **M.** [ENG-25]

12. **Готовность к релизу.**
    - Непрозрачная full-bleed иконка 1024 без alpha.
    - PrivacyInfo.xcprivacy: UserDefaults CA92.1, без трекинга и без сбора данных.
    - `MARKETING_VERSION` и `CURRENT_PROJECT_VERSION`; Settings показывает «Version X (N)» вместо «Preview» (SettingsView.swift:55).
    - `ITSAppUsesNonExemptEncryption = NO`.
    - Частичный Info.plist для массивных ключей.

    Файлы: Assets.xcassets, project.yml, SettingsView.swift, новые Info.plist и PrivacyInfo.xcprivacy. **S.** [UI-13, FN-D6, ENG-D3, FN-24]

### Фаза 2: переработка экранов (UX/UI)

1. **Слой архитектуры перед редизайном.**
   - AppModel на `@Observable`.
   - `PRStore` по PRKey: summary плюс detail, optimistic-обновления с откатом.
   - `PRDetailModel` с `LoadState` на секцию и одной `loadTask`.
   - Фоновый `CacheStore` с debounce.
   - Статические форматтеры дат.
   - GitHubClient становится Sendable, scopes возвращаются вместе с user.

   **L.** [ENG-22, FN-D5, ENG-16, ENG-D4, ENG-D5]

2. **Дизайн-токены.**
   - Динамические UIColor по образцу desktop Theme.swift:75-112: canvas F7F5F0/0C1220, panel, raised, line, accent 2A8BC8/5BB8EC, violet, coral D8513F/EE6F5F, green, red C2412F, amber, *Fill-варианты, addBG/delBG.
   - Asset AccentColor.
   - `PYType` на семантических стилях: serif только в hero и заголовке PR; `@ScaledMetric`; ViewThatFits для meta-строк.
   - `PYRadius` (10/16/24, continuous), `PYSpace`, `PYCard`.
   - `PYListStyle`: `.scrollContentBackground(.hidden)`, фон канвы, `listRowBackground`.
   - Бейдж вкладки coral; pill-текст не меньше 11 pt с глифом.

   Файлы: AppTheme.swift и все экраны. **M.** [UI-2, UI-12, UI-22, UI-11, UI-D5]

3. **Анимированный логотип.**
   - Порт `LogoGeometry`, `PullYardLogoMark`, `LogoDrawOn`, `PullYardLoader` из Sources/PullYard/Shared/LogoLoader.swift; `Motion.reduced` заменить на `accessibilityReduceMotion`.
   - Компактный вариант меньше 28 pt: узлы, кривые, корпус; толщина линии не меньше 1.5 pt; квадратная рамка.
   - `style: .brand | .monochrome(Color)`, сохранить параметр `title`.
   - LogoDrawOn один раз на входе и при старте без кэша, цикл во всех остальных местах.
   - В toolbar loader убирается из иерархии, когда простаивает.
   - Reduce Motion: статичный знак с пульсом прозрачности.

   **M.** [UI-1, ENG-24, UI-D3]

4. **Единый refresh (`PYRefreshable`).**
   - Механизм из «Спорных моментов» на всех списках, пустых и error-состояниях (в ScrollView с `containerRelativeFrame`), на PR detail и результатах поиска.
   - Кнопка refresh в toolbar везде: иконка превращается в мини-логотип.
   - Свежесть сверху, нажимается.
   - Убрать `.bar`-полосу (InboxAndPullsView.swift:46, 189).
   - `lastUpdated` отдельно для каждого источника.

   **M.** [UX-7, FN-20, UI-17, UI-D1, ENG-D13]

5. **Очереди на GraphQL search.**
   - author, isDraft, merged, reviewDecision, `statusCheckRollup.state`, `comments.totalCount`, `labels(first:3)`, последний review от viewer.
   - Счётчики соседних очередей через aliases.

   Файлы: GitHubClient.swift, Models.swift. **M.** [FN-3, UX-4, ENG-10]

6. **Новая строка PR.**
   - Строка 1: repo · #n, справа короткое время.
   - Строка 2: заголовок `.headline`, до 2 строк.
   - Строка 3: аватар 20 pt и login, pill только при отличии от фильтра, review chip, справа CI-точка и счётчик комментариев.
   - До двух меток с контрастом, рассчитанным для каждой метки.
   - Аватары: `s=` в URL, увеличенный URLCache, NSCache декодированных изображений, инициалы как fallback.
   - `.accessibilityElement(children: .combine)` с собранной меткой.

   **M.** [UI-5, UX-4, UI-19, UX-18]

7. **Шапка Pull requests и проекты.**
   - Лента chips: Needs review N · My PRs N · Assigned · Mentioned · Reviewed, счётчики через `.numericText()`.
   - Menu фильтра в toolbar; снимаемые chips активных фильтров; всё в заголовке List.
   - Пикер проектов: EditButton в trailing, исправление `moveProjects`, «…» во время discovery.

   Файлы: InboxAndPullsView.swift, Models.swift. **M.** [UX-8, UI-16, UI-D6, FN-12, UX-22]

8. **Экран PR detail.**
   - Один ScrollView с закреплённым segment header; hero скроллится, inline-заголовок появляется после hero.
   - Skeleton через `.redacted` и shimmer: порт Shared/Shimmer.swift.
   - Tab bar скрыт; нижний action bar по ролям UI-D7: ревьюер — Approve / Request changes / Comment; «Approved ✓ · Review again».
   - После успеха: `.sensoryFeedback(.success)`, `.symbolEffect(.bounce)`, toast «Approved · repo#n · Next in queue ›».
   - Overlay `recentActions` с TTL ~10 мин против задержки индекса search.
   - Баннер «Из Inbox · review requested by @x»; после ревью соответствующий тред помечается прочитанным.

   **L.** [UI-8, UX-5, UI-D2, UI-D7, UX-13, ENG-D17, UX-D2]

9. **Markdown-рендерер.**
   - Блоки: заголовки, списки, task list, code fence (sunken-карточка, monospace, горизонтальный скролл, copy), quote, таблицы, изображения, `<details>` как DisclosureGroup.
   - Убирать `<!-- -->`; ```suggestion показывать как mini-diff.
   - Тело `.body`; «Show more» длиннее ~14 строк.

   **L.** [UI-7, FN-10, ENG-23]

10. **Timeline в Conversation.**
    - ThreadCard по `inReplyToId ?? id`: path chip, 4-6 строк `diffHunk` (декодировать), свёрнутые ответы, один Reply в root.
    - Пустые COMMENTED-ревью скрыты.
    - Рельса с аватарами; свои комментарии отмечены accent hairline.
    - Открытие на новейшем сообщении (`.defaultScrollAnchor(.bottom)`), pill «Jump to latest», optimistic-вставка и подсветка своего комментария.
    - Context menu: Quote reply, Copy link, Copy text, Open on GitHub.
    - Фильтры: All · Unresolved · Reviews.
    - Из нотификации — прыжок к `latest_comment_url`.

    **L.** [UI-9, UX-10, ENG-19, UX-D4]

11. **Вкладка Checks.**
    - CI-карточка в Overview с пропорциональной полосой и счётчиками.
    - Секции Failing / Running / Passed (свёрнута) / Skipped.
    - Длительность «Failed after 3m 12s»; conclusions без `_`.
    - Pending-иконка с `.pulse`, на iOS 18 `.rotate`; summary через markdown-рендерер.

    **M.** [UI-10, FN-5]

12. **Inbox.**
    - `all=true` с окном `since`; прочитанные строки тусклые.
    - Chips: Unread · All · Review requested · Mentions · Assigned · CI.
    - Reason chip с цветом: Review requested — coral, Mentioned — violet, Assigned — sky, CI — amber.
    - Аватар владельца репозитория; правильный глиф issue.
    - Leading swipe: Read/Unread. Trailing: Done (DELETE threads/{id}) с Undo на 4-5 с, Mute (PUT subscription ignored).
    - Mark all read с подтверждением и повторным запросом (PUT /notifications может вернуть 202).
    - Группы Today / Earlier; context menu; state pill и CI на PR-нотификациях.

    **M.** [UX-9, FN-7, UI-18, UX-D2]

13. **Эргономика композеров.**
    - Comment, Reply, Request changes: автофокус через `@FocusState`, detent `.large`.
    - Approve: компактный sheet с большой кнопкой в зоне большого пальца, свёрнутое «Add a note», полоса контекста (заголовок, CI, файлы).
    - Reply показывает цитату родителя; кнопка Send становится мини-логотипом во время отправки.

    **S/M.** [UX-D3, UI-23]

14. **Экран входа.**
    - Hero: navy или бумага, aurora (MeshGradient на iOS 18, размытые круги на iOS 17), LogoDrawOn 72 pt, волны-горизонт.
    - Карточка токена на material; `PasteButton` справа в поле; `.onSubmit` / `.submitLabel(.go)`.
    - Распознавание префикса: `ghp_` — ок, `github_pat_` — предупреждение про Inbox.
    - Interstitial при нехватке scope «Continue without Inbox»; «Session expired for @login».
    - Место под кнопку Device Flow. Reduce Motion уважается.

    **M.** [UI-15, UX-19, ENG-15]

15. **Жесты на строках PR.**
    - `.contextMenu(preview:)`: мини-карточка ~340×260 без сетевой загрузки; Open on GitHub, Copy link, Share, Approve… (открывает composer), Comment…
    - Leading swipe: Snooze, хранится по PRKey для каждого аккаунта.
    - Все действия продублированы в `accessibilityActions`.

    **S.** [UX-14, UX-18]

16. **Поиск.**
    - Результаты сохраняются при правке запроса; debounce от 3 символов и 500 мс; отмена и `activeQuery`.
    - `.searchable(text:tokens:)`, suggestions (недавние, репозитории, is:open, author:@me), `.searchScopes`.
    - Строка поиска переиспользует PullRequestRow; кнопка Search в toolbar убирается.

    **M.** [UX-16, ENG-21, FN-23]

17. **Доступность и пустые состояния.**
    - `.isHeader` на SectionEyebrow, подписи для метрик и иконок ссылок, announcements.
    - `PYEmptyState` с иллюстрацией гавани только после успешной загрузки с нулём элементов; для ошибок отдельная иллюстрация и Retry.

    **S.** [UX-18, UI-24]

### Фаза 3: недостающий функционал

0. **PR по проектам (приоритет владельца).**
   - Вкладка Projects: закреплённые проекты сверху, затем все репозитории аккаунта (GraphQL `viewer.repositories`, сортировка по активности), у каждого число открытых PR и сколько ждут моего ревью; поиск, закрепление свайпом, порядок.
   - Экран проекта: все PR репозитория любого автора, фильтры Open / Merged / Closed / All и «Ждут моего ревью» / «Мои», пагинация, pull-to-refresh, те же строки и действия.
   - В Pull requests группировка по проектам (секции с заголовком проекта и счётчиком, сворачиваются), переключатель в меню фильтров.

   **L.** [запрос владельца]

1. **Files changed v1 (read-only).**
   - Метрика Files открывает список файлов `GET /pulls/{n}/files` с пагинацией: статус, ±, фильтр по пути.
   - Нативный unified diff: LazyVStack построчно, токены addBG/delBG, gutter, soft-wrap по умолчанию, sticky-заголовок файла.
   - Существующие треды прикреплены под строками.
   - Бинарные и большие файлы через «Load diff» / нет патча.
   - Локальная отметка «Viewed»; обновить «Product boundaries» в ios/README.md.

   **L.** [UX-12, FN-1]

2. **Merge readiness и действия автора.**
   - Карточка вверху Overview: GraphQL `mergeStateStatus` и `reviewDecision`; чеклист approvals, required checks, unresolved, conflicts/behind, draft; каждая строка ведёт в свой раздел. Порт BranchRules и MergeReadiness с desktop.
   - В action bar автора: Merge (sheet с методом из `allow_*_merge`, squash title/body, delete branch, передаётся head `sha`, обработка 405/409), Enable auto-merge, Ready for review (GraphQL), Update branch.
   - Close, Reopen, Convert to draft — в overflow с подтверждением.
   - Проверка `viewerPermission`.

   **L.** [UX-11, FN-2, FN-4, ENG-17]

3. **Карточка Reviewers.**
   - Аватары со значком состояния.
   - «You approved · N new commits since» и Review again.
   - Re-request review для автора.

   **M.** [FN-13, UI-19]

4. **Resolve и Unresolve тредов.**
   - GraphQL `reviewThreads` (isResolved, isOutdated); решённые треды свёрнуты в строку 44 pt; счётчик Unresolved.

   **M.** [FN-6]

5. **CI-действия.**
   - Re-run failed и Re-run all для Actions: run id через check_suite.
   - Хвост лога через Range в sunken monospace-карточке.
   - Число annotations со ссылкой в diff.
   - Автоопрос каждые 15-30 с, пока Checks виден и есть pending.

   **M.** [FN-5]

6. **Deep links.**
   - `.environment(\.openURL)`: github.com pull/issue-ссылки открываются внутри приложения.
   - Схема `pullyard://` и `onOpenURL`.
   - Поле «Open PR link» в Search и предложение, когда в буфере PR URL.
   - NSUserActivity для Handoff на desktop.

   **S/M.** [ENG-D8, FN-18, UX-20]

7. **Бейдж, фоновое обновление и локальные уведомления.**
   - Зависит от Фазы 1, п.3.
   - App Group; BGAppRefreshTask с If-Modified-Since; diff с последним виденным набором; локальные нотификации о новых review requests, mentions, approved / changes requested / CI failed по моим PR, с действиями Open и Mark read.
   - Запрос разрешения с объяснением; тумблеры по причинам; бейдж иконки.
   - Честно написать, что время запуска определяет iOS.

   **L.** [FN-8, UX-20, FN-D3]

8. **Вход через Device Flow.**
   - Порт DeviceFlow; client id из `PYGitHubOAuthClientID`.
   - Крупный 8-символьный код с copy, «Open github.com/login/device», опрос с анимированным логотипом.
   - PAT остаётся во вторичном раскрытии; без ключа кнопка скрыта.
   - Маппинг 403 «org access pending».

   **M**, заблокировано client id. [FN-9]

9. **События timeline и «новое с прошлого визита».**
   - GraphQL `timelineItems`: коммиты, force-push, review requested, labeled, ready, merged — однострочные события на рельсе.
   - Список Commits (N).
   - Маркер визита по PRKey: coral-разделитель и точка на строке очереди.

   **M.** [FN-15]

10. **Реакции.** Декодировать rollup `reactions`, полоса chips, 6 emoji в long-press, optimistic с откатом, `.impact(.light)`. **S.** [FN-16]

11. **Issue detail и не-PR нотификации.**
    - Issue-экран на тех же компонентах: hero, markdown, timeline, composer, Close/Reopen.
    - CheckSuite ведёт на Checks PR с фильтром failing; Release — sheet с заметками.
    - Discussions остаются на GitHub.

    **M.** [FN-19]

12. **Метаданные PR.** Labels, assignees, milestone, «Closes #n» в Overview, быстрое действие «Assign me». **S.** [FN-14]

13. **Офлайн PR detail.** LRU на 30 последних PR по PRKey через CacheStore; мгновенный рендер с баннером «Offline · updated HH:MM». **S/M.** [FN-21]

14. **Settings.**
    - Notifications (Фаза 3, п.7); Pull requests: очередь и фильтр по умолчанию, метод merge, delete branch.
    - Reading: diff wrap, mark read on open.
    - Appearance: Style PullYard (по умолчанию) / System; Auto / Light / Dark.
    - Ссылки на changelog, roadmap и обратную связь.

    **M.** [FN-24, UI-D8]

### Фаза 4: полировка

1. **Motion и haptics по всему приложению.** `.selection` на chips и сегментах, `.impact(.light)` на Done, `.error` на сбоях, `.numericText()` на счётчиках, `.animation(.snappy, value: ids)` на списках. Всё с учётом Reduce Motion. **S.** [UI-20]
2. **iOS 26.** За `#available`: `Tab(role: .search)`, `.tabBarMinimizeBehavior`, `glassEffect` / GlassEffectContainer на action bar, toast и капсуле refresh, `.glassProminent` на CTA. Settings за аватаром в nav bar (по решению владельца). **M.** [UI-21]
3. **Иконка второго уровня.** Варианты dark и tinted, слоистый `.icon` в Icon Composer. **S.** [UI-13]
4. **Widget.** Small и medium: «Needs review N» и топ-3 PR с CI; accessory для Lock Screen; navy-канва, coral-счётчик. **L.** [FN-8]
5. **Композер второго уровня.** Клавиатурная панель Bold / Italic / Code / Quote / List / Link / @, Write/Preview через рендерер, автодополнение @ из участников. **M.** [FN-11, UI-23]
6. **Diff v2.** Комментарии на строке или диапазоне в pending review, pill «Finish review (N)» вместо primary, синхронизация `markFileAsViewed`. **L.** [FN-1, FN-6]
7. **Онбординг.** 3 карточки на фоне aurora с логотипом, можно пропустить. **S.** [UX-19]
8. **Сохранённые поиски и проекты.** Сохранённый поиск как chip очереди, мультивыбор проектов, избранные проекты. **M.** [UX-16, FN-23, UX-22]
9. **Брендовые мелочи.** Шаблон «Updated just now» после foreground refresh, проверка всех вкладок в light/dark и AX5 как часть definition of done. **S.** [ENG-20, UI-D5]

## Что сознательно НЕ делаем

- **ИИ-агенты, чат, раздел «Agents», ИИ-саммари.** Прямой запрет владельца.
- **Рендер body_html через WKWebView.** Даёт память, рывки при скролле, нет Dynamic Type и нативного выделения текста. Только нативный рендер.
- **Полноценный редактор кода и правка файлов в diff.** Мобильный клиент — для просмотра и ответа, не IDE. Даже v2 ограничен комментариями.
- **Approve одним свайпом.** Approval нельзя отозвать. Только через composer.
- **Отдельная вкладка Mentions и отдельная очередь team review с `read:org`.** Дублируют Inbox и `review-requested:@me`.
- **Push через свой сервер (APNs) и любой backend.** Обещание «no backend» остаётся; уведомления только локальные и best-effort.
- **Скрытие action bar при скролле.** Ломает досягаемость основных действий.
- **Live Activity, мультиаккаунт и GitHub Enterprise в этом цикле.** Большая стоимость при малой ценности сейчас. Ключи Keychain и кэша сразу проектируем как host+login, чтобы потом не мигрировать (FN-22).
- **Перехват universal links github.com.** Стороннему приложению это технически недоступно. Вместо этого Share/Action-путь, буфер обмена и in-app openURL.
- **Удаление брендовых элементов.** Только добавляем и полируем. Стиль System — опция, по умолчанию остаётся PullYard.
- **NWPathMonitor как источник правды об офлайне.** Только подсказка; состояние берётся из типизированных ошибок.

## Вопросы владельцу

1. **Объём diff.** Подтверждаешь, что v1 — read-only список файлов и патч с существующими тредами (Фаза 3), а комментарии на строках, pending review и синхронизация Viewed — в v2? И что «Product boundaries» в ios/README.md переписываем с «triage, not review» на «полноценное ревью с телефона»?
2. **OAuth client id для Device Flow.** Регистрируем GitHub OAuth App (или используем тот же, что у desktop, через `PYGitHubOAuthClientID`) и включаем «Sign in with GitHub» основной кнопкой? Без client id вход остаётся только по PAT.
3. **Информационная архитектура.** Переносим Settings в аватар в nav bar и оставляем 3 контентные вкладки (Pull requests, Inbox, Search; на iOS 26 Search — отдельная таблетка)? Это отход от «Four primary destinations» в ios/PLAN.md.
4. **Сторонняя зависимость для Markdown.** Разрешаешь поддерживаемый GFM-пакет (например swift-markdown-ui), затемизированный нашими токенами? Или только собственный рендерер без зависимостей (дольше, и таблицы, `<details>`, изображения придётся писать самим)?
5. **Фоновые функции и релиз.** Делаем в этом цикле фоновое обновление с локальными уведомлениями и бейджем, а widget в Фазе 4? Это требует App Group, миграции Keychain и подписи в Apple Developer-аккаунте. Есть ли аккаунт и bundle id для TestFlight?
