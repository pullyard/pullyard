(() => {
  const KEY = "pullyard-lang";
  const SUPPORTED = ["en", "ru", "hy"];
  const LOCALES = { en: "en-US", ru: "ru-RU", hy: "hy-AM" };
  const NAMES = { en: "English", ru: "Русский", hy: "Հայերեն" };

  const readLang = () => {
    try {
      const saved = localStorage.getItem(KEY);
      if (SUPPORTED.includes(saved)) return saved;
    } catch (e) {}
    const nav = (navigator.languages || [navigator.language || "en"]).map(l => String(l).slice(0, 2).toLowerCase());
    return nav.map(l => (l === "am" ? "hy" : l)).find(l => SUPPORTED.includes(l)) || "en";
  };
  const lang = readLang();

  const D = {
    "PullYard Stats": ["Статистика PullYard", "PullYard վիճակագրություն"],
    "Stats": ["Статистика", "Վիճակագրություն"],
    "Refresh": ["Обновить", "Թարմացնել"],
    "Connections": ["Подключения", "Միացումներ"],
    "Theme": ["Тема", "Թեմա"],
    "Sections": ["Разделы", "Բաժիններ"],
    "Language": ["Язык", "Լեզու"],
    "Overview": ["Обзор", "Ամփոփում"],
    "Website": ["Сайт", "Կայք"],
    "Downloads": ["Загрузки", "Ներբեռնումներ"],
    "GitHub": ["GitHub", "GitHub"],
    "Finish setting up": ["Завершите настройку", "Ավարտեք կարգավորումը"],
    "Some numbers need a connection. Everything stays in this browser.": ["Для части данных нужно подключение. Всё хранится только в этом браузере.", "Որոշ տվյալների համար անհրաժեշտ է միացում։ Ամեն ինչ մնում է այս դիտարկիչում։"],
    "Downloads and stars": ["Загрузки и звёзды", "Ներբեռնումներ և աստղեր"],
    "Public GitHub data, always on.": ["Публичные данные GitHub, всегда доступны.", "GitHub-ի հանրային տվյալներ, միշտ հասանելի։"],
    "GitHub token": ["Токен GitHub", "GitHub թոքեն"],
    "Repo visitors, clones and stargazers.": ["Посетители репозитория, клоны и звёзды.", "Ռեպոզիտորիայի այցելուներ, կլոններ և աստղեր։"],
    "Umami share link": ["Ссылка Umami", "Umami-ի հղում"],
    "Website visitors, sources and countries.": ["Посетители сайта, источники и страны.", "Կայքի այցելուներ, աղբյուրներ և երկրներ։"],
    "Tracking on the live site": ["Отслеживание на сайте", "Հետևում կայքում"],
    "Deploy the site with analytics.js. Visits appear within minutes.": ["Опубликуйте сайт с analytics.js. Визиты появятся через несколько минут.", "Հրապարակեք կայքը analytics.js-ով։ Այցերը կհայտնվեն մի քանի րոպեում։"],
    "done": ["готово", "պատրաստ է"],
    "· done": ["· готово", "· պատրաստ է"],
    "No tagged visits yet. Add ?utm_source=linkedin&utm_campaign=launch to links you share.": ["Визитов с метками пока нет. Добавляйте ?utm_source=linkedin&utm_campaign=launch к ссылкам, которыми делитесь.", "Նշված այցեր դեռ չկան։ Ավելացրեք ?utm_source=linkedin&utm_campaign=launch ձեր տարածած հղումներին։"],
    "Add token": ["Добавить токен", "Ավելացնել թոքեն"],
    "Connect": ["Подключить", "Միացնել"],
    "Add GitHub token": ["Добавить токен GitHub", "Ավելացնել GitHub թոքեն"],
    "Fix token": ["Исправить токен", "Ուղղել թոքենը"],
    "Connect Umami": ["Подключить Umami", "Միացնել Umami-ն"],
    "Fix connection": ["Исправить подключение", "Ուղղել միացումը"],
    "Loading…": ["Загрузка…", "Բեռնվում է…"],
    "Website visitors · 30 days": ["Посетители сайта · 30 дней", "Կայքի այցելուներ · 30 օր"],
    "Download clicks · 30 days": ["Клики «Скачать» · 30 дней", "«Ներբեռնել» սեղմումներ · 30 օր"],
    "Repo visitors · 14 days": ["Посетители репозитория · 14 дней", "Ռեպոզիտորիայի այցելուներ · 14 օր"],
    "Unique cloners · 14 days": ["Уникальные клоны · 14 дней", "Եզակի կլոնողներ · 14 օր"],
    "Stars": ["Звёзды", "Աստղեր"],
    "Forks": ["Форки", "Ֆորքեր"],
    "Open downloads": ["Открыть загрузки", "Բացել ներբեռնումները"],
    "Where people come from": ["Откуда приходят люди", "Որտեղից են գալիս մարդիկ"],
    "Downloads by platform": ["Загрузки по платформам", "Ներբեռնումներն ըստ հարթակի"],
    "All releases, all time": ["Все релизы, за всё время", "Բոլոր թողարկումները, ամբողջ ժամանակահատվածում"],
    "What the downloads are": ["Что это за загрузки", "Ինչ ներբեռնումներ են"],
    "New installs": ["Новые установки", "Նոր տեղադրումներ"],
    "Auto-updates": ["Автообновления", "Ավտոթարմացումներ"],
    "By release and file": ["По релизам и файлам", "Ըստ թողարկման և ֆայլի"],
    "Top countries": ["Топ стран", "Լավագույն երկրներ"],
    "All website stats": ["Вся статистика сайта", "Կայքի ամբողջ վիճակագրությունը"],
    "Website visitors by channel · 30 days": ["Посетители сайта по каналам · 30 дней", "Կայքի այցելուներն ըստ ալիքի · 30 օր"],
    "Sites that sent people to the GitHub repo · 14 days": ["Сайты, приводившие людей в репозиторий · 14 дней", "Կայքեր, որոնք մարդկանց բերել են ռեպոզիտորիա · 14 օր"],
    "Website sources appear here once Umami has visits.": ["Источники появятся здесь, когда в Umami будут визиты.", "Աղբյուրները կհայտնվեն այստեղ, երբ Umami-ում այցեր լինեն։"],
    "No source data yet": ["Пока нет данных об источниках", "Աղբյուրների տվյալներ դեռ չկան"],
    "Connect Umami to see where website visitors come from.": ["Подключите Umami, чтобы видеть, откуда приходят посетители.", "Միացրեք Umami-ն՝ տեսնելու, թե որտեղից են գալիս այցելուները։"],
    "Sources appear after the first visits to the live site.": ["Источники появятся после первых визитов на сайт.", "Աղբյուրները կհայտնվեն կայքի առաջին այցերից հետո։"],

    "Visitors of pullyard.app, tracked by Umami without cookies": ["Посетители pullyard.app, учёт через Umami без cookies", "pullyard.app-ի այցելուներ՝ Umami-ով, առանց cookie-ների"],
    "Period": ["Период", "Ժամանակահատված"],
    "7 days": ["7 дней", "7 օր"],
    "14 days": ["14 дней", "14 օր"],
    "30 days": ["30 дней", "30 օր"],
    "90 days": ["90 дней", "90 օր"],
    "All": ["Всё", "Բոլորը"],
    "Visitors": ["Посетители", "Այցելուներ"],
    "Visits": ["Визиты", "Այցեր"],
    "Page views": ["Просмотры", "Էջադիտումներ"],
    "Bounce rate": ["Отказы", "Մերժումներ"],
    "Average visit": ["Средний визит", "Միջին այց"],
    "Download clicks": ["Клики «Скачать»", "«Ներբեռնել» սեղմումներ"],
    "No change": ["Без изменений", "Առանց փոփոխության"],
    "Page views and visits": ["Просмотры и визиты", "Էջադիտումներ և այցեր"],
    "Per day, in your time zone": ["По дням, в вашем часовом поясе", "Ըստ օրերի, ձեր ժամային գոտում"],
    "Table": ["Таблица", "Աղյուսակ"],
    "Chart": ["График", "Գրաֆիկ"],
    "Where visitors are": ["Где находятся посетители", "Որտեղ են այցելուները"],
    "Visitors by location, worked out from their IP address. Umami doesn't store the IP.": ["Местоположение определяется по IP-адресу. Umami не хранит IP.", "Գտնվելու վայրը որոշվում է IP հասցեով։ Umami-ն IP-ն չի պահում։"],
    "Location level": ["Уровень местоположения", "Վայրի մակարդակ"],
    "Countries": ["Страны", "Երկրներ"],
    "Regions": ["Регионы", "Տարածաշրջաններ"],
    "Cities": ["Города", "Քաղաքներ"],
    "Languages": ["Языки", "Լեզուներ"],
    "servers": ["серверы", "սերվերներ"],
    "Cloud data-center town. Visits from here are usually bots.": ["Город с облачными дата-центрами. Визиты отсюда обычно от ботов.", "Ամպային տվյալների կենտրոնների քաղաք։ Այստեղից այցերը սովորաբար բոտեր են։"],
    "Channels": ["Каналы", "Ալիքներ"],
    "How visitors found the site": ["Как посетители нашли сайт", "Ինչպես են այցելուները գտել կայքը"],
    "Referring sites": ["Ссылающиеся сайты", "Հղող կայքեր"],
    "Pages that linked to the site": ["Страницы со ссылкой на сайт", "Կայքին հղում տված էջեր"],
    "Clicks on download buttons, by platform": ["Клики по кнопкам загрузки, по платформам", "Ներբեռնման կոճակների սեղմումներ՝ ըստ հարթակի"],
    "Other clicks": ["Другие клики", "Այլ սեղմումներ"],
    "No download clicks yet": ["Кликов по загрузке пока нет", "Ներբեռնման սեղմումներ դեռ չկան"],
    "Pages": ["Страницы", "Էջեր"],
    "Most visited pages": ["Самые посещаемые страницы", "Ամենաայցելված էջերը"],
    "Page": ["Страница", "Էջ"],
    "Views": ["Просмотры", "Դիտումներ"],
    "No page views yet": ["Просмотров пока нет", "Էջադիտումներ դեռ չկան"],
    "Campaigns": ["Кампании", "Արշավներ"],
    "Visits from links tagged with": ["Визиты по ссылкам с метками", "Այցեր այն հղումներից, որոնք նշված են"],
    "and": ["и", "և"],
    "Source": ["Источник", "Աղբյուր"],
    "Campaign": ["Кампания", "Արշավ"],
    "Devices": ["Устройства", "Սարքեր"],
    "Visitors by operating system, browser and device type": ["Посетители по ОС, браузеру и типу устройства", "Այցելուներն ըստ ՕՀ-ի, դիտարկիչի և սարքի տեսակի"],
    "Operating system": ["Операционная система", "Օպերացիոն համակարգ"],
    "Browser": ["Браузер", "Դիտարկիչ"],
    "Device": ["Устройство", "Սարք"],
    "Desktop": ["Компьютер", "Համակարգիչ"],
    "Laptop": ["Ноутбук", "Նոութբուք"],
    "Mobile": ["Телефон", "Հեռախոս"],
    "Tablet": ["Планшет", "Պլանշետ"],
    "No data yet": ["Данных пока нет", "Տվյալներ դեռ չկան"],
    "Direct": ["Прямые заходы", "Ուղիղ"],
    "Other websites": ["Другие сайты", "Այլ կայքեր"],
    "Search engines": ["Поисковики", "Որոնողական համակարգեր"],
    "Social networks": ["Соцсети", "Սոցցանցեր"],
    "Video": ["Видео", "Տեսանյութ"],
    "Shopping": ["Покупки", "Գնումներ"],
    "Email": ["Email", "Էլ. փոստ"],
    "Paid ads": ["Платная реклама", "Վճարովի գովազդ"],
    "Paid search": ["Платный поиск", "Վճարովի որոնում"],
    "Paid social": ["Платные соцсети", "Վճարովի սոցցանցեր"],
    "Paid video": ["Платное видео", "Վճարովի տեսանյութ"],
    "Paid shopping": ["Платные покупки", "Վճարովի գնումներ"],
    "GitHub repo": ["Репозиторий GitHub", "GitHub ռեպոզիտորիա"],
    "Releases page": ["Страница релизов", "Թողարկումների էջ"],
    "Install command copied": ["Скопирована команда установки", "Տեղադրման հրամանը պատճենվել է"],
    "Other file": ["Другой файл", "Այլ ֆայլ"],
    "Connect Umami to see website visitors": ["Подключите Umami, чтобы видеть посетителей", "Միացրեք Umami-ն՝ այցելուներին տեսնելու համար"],
    "See who visits pullyard.app, where they come from, their countries and how many click Download. Free Umami plan works through a share link.": ["Смотрите, кто заходит на pullyard.app, откуда, из каких стран и сколько нажимают «Скачать». Бесплатный план Umami работает через ссылку.", "Տեսեք՝ ով է այցելում pullyard.app, որտեղից, որ երկրներից և քանիսն են սեղմում «Ներբեռնել»։ Umami-ի անվճար պլանն աշխատում է հղումով։"],
    "Couldn't load website stats": ["Не удалось загрузить статистику сайта", "Չհաջողվեց բեռնել կայքի վիճակագրությունը"],
    "Check connection": ["Проверить подключение", "Ստուգել միացումը"],
    "Loading website stats": ["Загружаем статистику сайта", "Բեռնվում է կայքի վիճակագրությունը"],
    "Umami is connected. Visits show up after the site with docs/site/analytics.js is live on pullyard.app. Visits from localhost aren't counted.": ["Umami подключён. Визиты появятся, когда сайт с docs/site/analytics.js будет опубликован на pullyard.app. Визиты с localhost не учитываются.", "Umami-ն միացված է։ Այցերը կհայտնվեն, երբ docs/site/analytics.js-ով կայքը հրապարակվի pullyard.app-ում։ localhost-ից այցերը չեն հաշվվում։"],
    "Visitors in the last 5 minutes": ["Посетители за последние 5 минут", "Այցելուներ վերջին 5 րոպեում"],
    "No one on the site now": ["Сейчас на сайте никого", "Այժմ կայքում ոչ ոք չկա"],

    "Files downloaded from GitHub Releases": ["Файлы, скачанные с GitHub Releases", "GitHub Releases-ից ներբեռնված ֆայլեր"],
    "Count": ["Подсчёт", "Հաշվարկ"],
    "All downloads": ["Все загрузки", "Բոլոր ներբեռնումները"],
    "New installs only": ["Только новые установки", "Միայն նոր տեղադրումներ"],
    "About the two counts": ["О двух способах подсчёта", "Երկու հաշվարկի մասին"],
    "By platform": ["По платформам", "Ըստ հարթակի"],
    "Over time": ["Динамика", "Ժամանակի ընթացքում"],
    "Total so far, saved each time you open this page": ["Итог на сегодня, сохраняется при каждом открытии страницы", "Ընդհանուրը, պահվում է ամեն անգամ էջը բացելիս"],
    "By release": ["По релизам", "Ըստ թողարկման"],
    "Downloads of each version's files": ["Загрузки файлов каждой версии", "Յուրաքանչյուր տարբերակի ֆայլերի ներբեռնումները"],
    "By file": ["По файлам", "Ըստ ֆայլի"],
    "All releases, grouped by platform, format and architecture": ["Все релизы по платформе, формату и архитектуре", "Բոլոր թողարկումները՝ ըստ հարթակի, ձևաչափի և ճարտարապետության"],
    "Latest release": ["Последний релиз", "Վերջին թողարկումը"],
    "Top platform": ["Главная платформа", "Գլխավոր հարթակ"],
    "Installed by the app itself": ["Установлены самим приложением", "Տեղադրվել են հավելվածի կողմից"],
    "By processor": ["По процессору", "Ըստ պրոցեսորի"],
    "New installs, auto-updates subtracted": ["Новые установки, без автообновлений", "Նոր տեղադրումներ՝ առանց ավտոթարմացումների"],
    "Every installer download": ["Каждая загрузка установщика", "Տեղադրիչի յուրաքանչյուր ներբեռնում"],
    "The trend starts today. Open this page again tomorrow to see it grow.": ["Тренд начинается сегодня. Откройте страницу завтра, чтобы увидеть рост.", "Միտումը սկսվում է այսօր։ Վաղը կրկին բացեք էջը՝ աճը տեսնելու համար։"],
    "Platform": ["Платформа", "Հարթակ"],
    "Share": ["Доля", "Մասնաբաժին"],
    "Date": ["Дата", "Ամսաթիվ"],
    "Total": ["Всего", "Ընդամենը"],
    "Version": ["Версия", "Տարբերակ"],
    "Published": ["Опубликован", "Հրապարակվել է"],
    "Format": ["Формат", "Ձևաչափ"],
    "Processor": ["Процессор", "Պրոցեսոր"],
    "Other": ["Другое", "Այլ"],
    "Installer": ["Установщик", "Տեղադրիչ"],
    "Portable": ["Портативная", "Շարժական"],
    "Universal": ["Универсальная", "Ունիվերսալ"],

    "Visits, clones and stars of the pullyard/pullyard repository": ["Визиты, клоны и звёзды репозитория pullyard/pullyard", "pullyard/pullyard ռեպոզիտորիայի այցերը, կլոնները և աստղերը"],
    "Repository traffic": ["Трафик репозитория", "Ռեպոզիտորիայի տրաֆիկ"],
    "Metric": ["Метрика", "Ցուցանիշ"],
    "Clones": ["Клоны", "Կլոններ"],
    "GitHub keeps 14 days. Older days come from this browser's saved history.": ["GitHub хранит 14 дней. Более ранние дни берутся из истории этого браузера.", "GitHub-ը պահում է 14 օր։ Ավելի հին օրերը վերցվում են այս դիտարկիչի պատմությունից։"],
    "Where repo visitors came from · 14 days": ["Откуда пришли посетители репозитория · 14 дней", "Որտեղից են եկել ռեպոզիտորիայի այցելուները · 14 օր"],
    "Popular pages": ["Популярные страницы", "Հանրաճանաչ էջեր"],
    "Most viewed pages in the repo · 14 days": ["Самые просматриваемые страницы репозитория · 14 дней", "Ռեպոզիտորիայի ամենադիտված էջերը · 14 օր"],
    "Community": ["Сообщество", "Համայնք"],
    "Stars over time": ["Звёзды во времени", "Աստղերը ժամանակի ընթացքում"],
    "Latest stargazers": ["Последние звёзды", "Վերջին աստղ դնողները"],
    "Starred by": ["Кто поставил", "Աստղ է դրել"],
    "No stars yet": ["Звёзд пока нет", "Աստղեր դեռ չկան"],
    "Unique visitors": ["Уникальные посетители", "Եզակի այցելուներ"],
    "Unique cloners": ["Уникальные клоны", "Եզակի կլոնողներ"],
    "Unique": ["Уникальные", "Եզակի"],
    "Needs a token": ["Нужен токен", "Անհրաժեշտ է թոքեն"],
    "None new in 14 days": ["Новых за 14 дней нет", "14 օրում նորեր չկան"],
    "Add a GitHub token to see repo traffic": ["Добавьте токен GitHub, чтобы видеть трафик", "Ավելացրեք GitHub թոքեն՝ տրաֆիկը տեսնելու համար"],
    "GitHub only shows views, clones, referring sites and stargazers to people who can push to the repo. A read-only token is enough.": ["GitHub показывает просмотры, клоны, источники и звёзды только тем, у кого есть доступ на запись. Достаточно токена только для чтения.", "GitHub-ը դիտումները, կլոնները, աղբյուրները և աստղերը ցույց է տալիս միայն գրելու իրավունք ունեցողներին։ Բավական է միայն կարդալու թոքենը։"],
    "Traffic isn't available": ["Трафик недоступен", "Տրաֆիկը հասանելի չէ"],
    "Check token": ["Проверить токен", "Ստուգել թոքենը"],
    "GitHub didn't return traffic for this token.": ["GitHub не вернул трафик для этого токена.", "GitHub-ը այս թոքենի համար տրաֆիկ չվերադարձրեց։"],
    "GitHub didn't return the stargazer list.": ["GitHub не вернул список звёзд.", "GitHub-ը աստղ դնողների ցանկը չվերադարձրեց։"],
    "GitHub only lists stargazers to signed-in requests. Add a token to see who starred.": ["GitHub показывает, кто поставил звезду, только с токеном. Добавьте токен.", "GitHub-ը աստղ դնողներին ցույց է տալիս միայն թոքենով։ Ավելացրեք թոքեն։"],

    "Downloads and stars work without anything. Connections unlock the rest. Keys and links are saved only in this browser.": ["Загрузки и звёзды работают без настройки. Подключения открывают остальное. Ключи и ссылки хранятся только в этом браузере.", "Ներբեռնումներն ու աստղերն աշխատում են առանց կարգավորման։ Միացումները բացում են մնացածը։ Բանալիներն ու հղումները պահվում են միայն այս դիտարկիչում։"],
    "Close": ["Закрыть", "Փակել"],
    "Unlocks repo visitors, clones, referring sites and stargazers.": ["Открывает посетителей репозитория, клоны, источники и звёзды.", "Բացում է ռեպոզիտորիայի այցելուները, կլոնները, աղբյուրները և աստղերը։"],
    "Personal access token": ["Персональный токен доступа", "Անձնական մուտքի թոքեն"],
    "Remember on this device": ["Запомнить на этом устройстве", "Հիշել այս սարքում"],
    "Save token": ["Сохранить токен", "Պահել թոքենը"],
    "Remove": ["Удалить", "Հեռացնել"],
    "How to create the token": ["Как создать токен", "Ինչպես ստեղծել թոքեն"],
    "Open": ["Откройте", "Բացեք"],
    "new fine-grained token": ["новый fine-grained токен", "նոր fine-grained թոքեն"],
    "Resource owner": ["Владелец ресурса", "Ռեսուրսի սեփականատեր"],
    ", repository access": [", доступ к репозиториям", ", ռեպոզիտորիաների հասանելիություն"],
    "Only select repositories → pullyard": ["Только выбранные репозитории → pullyard", "Միայն ընտրված ռեպոզիտորիաներ → pullyard"],
    "Repository permissions:": ["Права репозитория:", "Ռեպոզիտորիայի իրավունքներ՝"],
    "Administration → Read-only": ["Administration → Только чтение", "Administration → Միայն կարդալ"],
    ". Nothing else.": [". Больше ничего.", "։ Ուրիշ ոչինչ։"],
    "Unlocks website visitors, channels, countries and download clicks.": ["Открывает посетителей сайта, каналы, страны и клики по загрузке.", "Բացում է կայքի այցելուները, ալիքները, երկրները և ներբեռնման սեղմումները։"],
    "Share link": ["Ссылка для просмотра", "Դիտման հղում"],
    "Umami Pro: use an API key instead": ["Umami Pro: используйте API-ключ", "Umami Pro՝ օգտագործեք API բանալի"],
    "Website ID": ["ID сайта", "Կայքի ID"],
    "API key": ["API-ключ", "API բանալի"],
    "Save": ["Сохранить", "Պահել"],
    "Disconnect": ["Отключить", "Անջատել"],
    "Where to find the share link": ["Где найти ссылку", "Որտեղ գտնել հղումը"],
    "Umami → Settings → Websites → pullyard.app → Share.": ["Umami → Settings → Websites → pullyard.app → Share.", "Umami → Settings → Websites → pullyard.app → Share։"],
    "Turn on": ["Включите", "Միացրեք"],
    ", save, copy the link.": [", сохраните и скопируйте ссылку.", ", պահեք և պատճենեք հղումը։"],
    "Events": ["Events", "Events"],
    "Anyone with the link can see the stats, so keep it private.": ["Любой со ссылкой увидит статистику, не делитесь ею.", "Հղում ունեցող ցանկացած մեկը կտեսնի վիճակագրությունը, մի՛ տարածեք այն։"],
    "Connected": ["Подключено", "Միացված է"],
    "Not connected": ["Не подключено", "Միացված չէ"],
    "Needs attention": ["Требует внимания", "Պահանջում է ուշադրություն"],
    "Checking…": ["Проверка…", "Ստուգվում է…"],
    "Saved. Paste a new token to replace it": ["Сохранён. Вставьте новый, чтобы заменить", "Պահված է։ Տեղադրեք նորը՝ փոխարինելու համար"],
    "Saved. Paste a new key to replace it": ["Сохранён. Вставьте новый, чтобы заменить", "Պահված է։ Տեղադրեք նորը՝ փոխարինելու համար"],
    "Paste a token first.": ["Сначала вставьте токен.", "Նախ տեղադրեք թոքենը։"],
    "Paste the API key.": ["Вставьте API-ключ.", "Տեղադրեք API բանալին։"],
    "Paste the share link, or a Website ID and API key.": ["Вставьте ссылку или ID сайта и API-ключ.", "Տեղադրեք հղումը կամ կայքի ID-ն և API բանալին։"],
    "That doesn't look like an Umami share link. It contains /share/ followed by a code.": ["Это не похоже на ссылку Umami. В ней есть /share/ и код.", "Սա Umami-ի հղման նման չէ։ Այն պարունակում է /share/ և կոդ։"],
    "Umami rejected the share link.": ["Umami отклонил ссылку.", "Umami-ն մերժեց հղումը։"],
    "Umami rejected the API key.": ["Umami отклонил API-ключ.", "Umami-ն մերժեց API բանալին։"],
    "Umami can't find that Website ID.": ["Umami не нашёл такой ID сайта.", "Umami-ն չգտավ այդ կայքի ID-ն։"],
    "Umami can't find that share link. Check that sharing is on for the website.": ["Umami не нашёл ссылку. Проверьте, что доступ по ссылке включён.", "Umami-ն չգտավ հղումը։ Ստուգեք, որ հղումով դիտումը միացված է։"],
    "The token was rejected. It may have expired.": ["Токен отклонён. Возможно, он истёк.", "Թոքենը մերժվեց։ Հնարավոր է՝ ժամկետն անցել է։"],
    "The token can't read this. Give it Administration: Read-only on pullyard/pullyard.": ["У токена нет доступа. Дайте ему Administration: Read-only на pullyard/pullyard.", "Թոքենը մուտք չունի։ Տվեք Administration: Read-only pullyard/pullyard-ի համար։"],
    "Failed to fetch": ["Не удалось выполнить запрос. Возможно, его блокирует браузер.", "Հարցումը չհաջողվեց։ Հնարավոր է՝ այն արգելափակում է դիտարկիչը։"],
    "just now": ["только что", "հենց նոր"],
    "yesterday": ["вчера", "երեկ"],

    "How many times installer files were downloaded from GitHub Releases, across all versions. It includes auto-updates and Homebrew installs, so it's higher than the number of people.": ["Сколько раз установщики скачали с GitHub Releases по всем версиям. Включает автообновления и Homebrew, поэтому больше числа людей.", "Քանի անգամ են տեղադրիչները ներբեռնվել GitHub Releases-ից՝ բոլոր տարբերակներով։ Ներառում է ավտոթարմացումները և Homebrew-ը, ուստի ավելի շատ է, քան մարդկանց թիվը։"],
    "All downloads vs new installs": ["Все загрузки и новые установки", "Բոլոր ներբեռնումները և նոր տեղադրումները"],
    "All downloads counts every installer download. New installs only subtracts auto-updates (the app downloads a .sig file with each update). Homebrew installs can't be separated and stay in both.": ["«Все загрузки» считает каждую загрузку установщика. «Только новые установки» вычитает автообновления (с каждым обновлением приложение скачивает файл .sig). Установки через Homebrew не отделить, они есть в обоих.", "«Բոլոր ներբեռնումները» հաշվում է տեղադրիչի յուրաքանչյուր ներբեռնում։ «Միայն նոր տեղադրումները» հանում է ավտոթարմացումները (յուրաքանչյուր թարմացմամբ հավելվածը ներբեռնում է .sig ֆայլ)։ Homebrew-ի տեղադրումները հնարավոր չէ առանձնացնել։"],
    "Installer downloads minus auto-updates. The closest estimate of new installs, though it still includes Homebrew and repeat downloads.": ["Загрузки установщика минус автообновления. Ближайшая оценка новых установок, хотя сюда входят Homebrew и повторные загрузки.", "Տեղադրիչի ներբեռնումները՝ հանած ավտոթարմացումները։ Նոր տեղադրումների ամենամոտ գնահատականը, թեև ներառում է Homebrew-ը և կրկնակի ներբեռնումները։"],
    "Updates the app installed by itself. Each one downloads a signature file (.sig) from the release, which is what's counted here.": ["Обновления, которые приложение установило само. Каждое скачивает файл подписи (.sig), его и считаем.", "Թարմացումներ, որոնք հավելվածը տեղադրել է ինքնուրույն։ Յուրաքանչյուրը ներբեռնում է ստորագրության ֆայլ (.sig), որն էլ հաշվվում է։"],
    "Downloads of the newest version's files since it was published.": ["Загрузки файлов новейшей версии с момента публикации.", "Ամենանոր տարբերակի ֆայլերի ներբեռնումները՝ հրապարակումից ի վեր։"],
    "Releases": ["Релизы", "Թողարկումներ"],
    "Number of published versions that have downloadable files.": ["Число опубликованных версий с файлами для загрузки.", "Ներբեռնվող ֆայլերով հրապարակված տարբերակների քանակը։"],
    "Website visitors": ["Посетители сайта", "Կայքի այցելուներ"],
    "Unique people who opened pullyard.app, counted by Umami without cookies. Your own local test visits aren't counted.": ["Уникальные люди, открывшие pullyard.app, по данным Umami без cookies. Ваши локальные тестовые визиты не учитываются.", "Եզակի մարդիկ, ովքեր բացել են pullyard.app-ը, ըստ Umami-ի՝ առանց cookie-ների։ Ձեր տեղային փորձնական այցերը չեն հաշվվում։"],
    "Sessions on the site. One visitor can come back several times.": ["Сеансы на сайте. Один посетитель может вернуться несколько раз.", "Այցեր կայքում։ Մեկ այցելուն կարող է վերադառնալ մի քանի անգամ։"],
    "Every page opened, including repeat views.": ["Каждая открытая страница, включая повторы.", "Յուրաքանչյուր բացված էջ, ներառյալ կրկնակի դիտումները։"],
    "Share of visits that opened one page and left without another tracked action. Lower is better.": ["Доля визитов с одной страницей без других действий. Чем меньше, тем лучше.", "Այն այցերի մասնաբաժինը, որոնք բացել են մեկ էջ և հեռացել առանց այլ գործողության։ Որքան ցածր, այնքան լավ։"],
    "Average time between the first and last action in a visit.": ["Среднее время между первым и последним действием за визит.", "Այցի առաջին և վերջին գործողության միջև միջին ժամանակը։"],
    "Clicks on download buttons on the website. Each click starts a download from GitHub Releases.": ["Клики по кнопкам загрузки на сайте. Каждый клик начинает загрузку с GitHub Releases.", "Կայքի ներբեռնման կոճակների սեղմումներ։ Յուրաքանչյուր սեղմում սկսում է ներբեռնում GitHub Releases-ից։"],
    "Repo visitors": ["Посетители репозитория", "Ռեպոզիտորիայի այցելուներ"],
    "Unique GitHub users or browsers who opened the repository. GitHub only keeps the last 14 days.": ["Уникальные пользователи или браузеры, открывшие репозиторий. GitHub хранит только 14 дней.", "Եզակի օգտատերեր կամ դիտարկիչներ, որոնք բացել են ռեպոզիտորիան։ GitHub-ը պահում է միայն վերջին 14 օրը։"],
    "Unique accounts or machines that ran git clone in the last 14 days.": ["Уникальные аккаунты или машины, выполнившие git clone за 14 дней.", "Եզակի հաշիվներ կամ մեքենաներ, որոնք վերջին 14 օրում կատարել են git clone։"],
    "People who starred the repository on GitHub.": ["Люди, поставившие репозиторию звезду на GitHub.", "Մարդիկ, ովքեր GitHub-ում աստղ են դրել ռեպոզիտորիային։"],
    "Copies of the repository made on GitHub.": ["Копии репозитория на GitHub.", "Ռեպոզիտորիայի պատճենները GitHub-ում։"],
    "About downloads": ["О загрузках", "Ներբեռնումների մասին"],
    "About website visitors": ["О посетителях сайта", "Կայքի այցելուների մասին"],
    "About download clicks": ["О кликах по загрузке", "Ներբեռնման սեղմումների մասին"],
    "About repo visitors": ["О посетителях репозитория", "Ռեպոզիտորիայի այցելուների մասին"],
    "About stars": ["О звёздах", "Աստղերի մասին"]
  };

  const N = "([\\d\\s\\u00a0\\u202f.,]+)";
  const P = [
    [`^(\\d+)s$`, "$1 с", "$1 վ"],
    [`^(\\d+)m (\\d+)s$`, "$1 мин $2 с", "$1 ր $2 վ"],
    [`^(\\d+)h (\\d+)m$`, "$1 ч $2 мин", "$1 ժ $2 ր"],
    [`^Updated (.+)$`, "Обновлено ~1", "Թարմացվել է ~1"],
    [`^Stale · updated (.+)$`, "Устарело · обновлено ~1", "Հնացած · թարմացվել է ~1"],
    [`^${N} min ago$`, "$1 мин назад", "$1 րոպե առաջ"],
    [`^${N} h ago$`, "$1 ч назад", "$1 ժամ առաջ"],
    [`^${N} days ago$`, "$1 дн. назад", "$1 օր առաջ"],
    [`^${N} per 100 visitors$`, "$1 на 100 посетителей", "$1՝ 100 այցելուից"],
    [`^${N} on the site now$`, "Сейчас на сайте: $1", "Այժմ կայքում՝ $1"],
    [`^${N} open issues$`, "Открытых задач: $1", "$1 բաց խնդիր"],
    [`^${N} page views$`, "Просмотров: $1", "$1 էջադիտում"],
    [`^${N} views$`, "Просмотров: $1", "$1 դիտում"],
    [`^${N} clones$`, "Клонов: $1", "$1 կլոն"],
    [`^${N} unique$`, "Уникальных: $1", "$1 եզակի"],
    [`^${N} watching$`, "Следят: $1", "$1 հետևող"],
    [`^${N} forks$`, "Форков: $1", "$1 ֆորք"],
    [`^${N} forks · ${N} watching$`, "Форков: $1 · следят: $2", "$1 ֆորք · $2 հետևող"],
    [`^${N} releases$`, "Релизов: $1", "$1 թողարկում"],
    [`^\\+${N} in the last 14 days$`, "+$1 за 14 дней", "+$1 վերջին 14 օրում"],
    [`^About ${N} of ${N} visitors \\((.+)\\)$`, "Около $1 из $2 посетителей ($3)", "Մոտ $1-ը $2 այցելուից ($3)"],
    [`^came from cloud data-center towns like (.+)\\. They're usually bots, crawlers or link previews, not people\\.$`, "пришли из городов с облачными дата-центрами ($1). Обычно это боты, краулеры или превью ссылок, а не люди.", "եկել են ամպային տվյալների կենտրոնների քաղաքներից ($1)։ Սովորաբար դրանք բոտեր, սողացողներ կամ հղումների նախադիտումներ են, ոչ թե մարդիկ։"],
    [`^About ${N} new installs, the rest are auto-updates$`, "Около $1 новых установок, остальное — автообновления", "Մոտ $1 նոր տեղադրում, մնացածը ավտոթարմացումներ են"],
    [`^since (.+) · about ${N} new installs$`, "с $1 · около $2 новых установок", "$1-ից ի վեր · մոտ $2 նոր տեղադրում"],
    [`^No visits in the last ${N} days$`, "Нет визитов за последние $1 дн.", "Վերջին $1 օրում այցեր չկան"],
    [`^Asking Umami for the last ${N} days\\.$`, "Запрашиваем у Umami последние $1 дн.", "Umami-ից խնդրում ենք վերջին $1 օրը։"],
    [`^Show all ${N} countries$`, "Показать все страны ($1)", "Ցույց տալ բոլոր երկրները ($1)"],
    [`^Show all ${N} regions$`, "Показать все регионы ($1)", "Ցույց տալ բոլոր տարածաշրջանները ($1)"],
    [`^Show all ${N} cities$`, "Показать все города ($1)", "Ցույց տալ բոլոր քաղաքները ($1)"],
    [`^Show all ${N} languages$`, "Показать все языки ($1)", "Ցույց տալ բոլոր լեզուները ($1)"],
    [`^Show top ${N}$`, "Показать топ-$1", "Ցույց տալ լավագույն $1-ը"],
    [`^Since the repo was created on (.+)$`, "С создания репозитория $1", "Ռեպոզիտորիայի ստեղծումից՝ $1"],
    [`^Connections, ${N} not set up$`, "Подключения, не настроено: $1", "Միացումներ, չկարգավորված՝ $1"],
    [`^Theme: auto$`, "Тема: авто", "Թեմա՝ ավտոմատ"],
    [`^Theme: light$`, "Тема: светлая", "Թեմա՝ բաց"],
    [`^Theme: dark$`, "Тема: тёмная", "Թեմա՝ մուգ"],
    [`^Data from the GitHub API and Umami\\.$`, "Данные из GitHub API и Umami.", "Տվյալները GitHub API-ից և Umami-ից։"],
    [`^Data from the GitHub API and Umami\\. GitHub API calls left: ${N} of ${N}, resets (.+)\\.$`, "Данные из GitHub API и Umami. Осталось запросов к GitHub API: $1 из $2, сброс в $3.", "Տվյալները GitHub API-ից և Umami-ից։ Մնացել է GitHub API հարցում՝ $1-ը $2-ից, վերակայում՝ $3։"],
    [`^vs prior ${N} days$`, "к прошлым $1 дн.", "նախորդ $1 օրվա համեմատ"],
    [`^(.+) of downloads$`, "$1 загрузок", "ներբեռնումների $1-ը"],
    [`^v(\\S+) · (.+)$`, "v$1 · ~2", "v$1 · ~2"],
    [`^(.+) · region (.+)$`, "$1 · регион $2", "$1 · տարածաշրջան $2"],
    [`^GitHub returned (\\d+)\\.$`, "GitHub вернул $1.", "GitHub-ը վերադարձրեց $1։"],
    [`^Umami returned (\\d+)\\.$`, "Umami вернул $1.", "Umami-ն վերադարձրեց $1։"],
    [`^GitHub rate limit reached\\. Try again after (.+)\\.$`, "Лимит запросов GitHub исчерпан. Повторите после $1.", "GitHub-ի հարցումների սահմանաչափը սպառված է։ Կրկին փորձեք $1-ից հետո։"]
  ].map(([re, ru, hy]) => [new RegExp(re), { ru, hy }]);

  function tr(text) {
    if (lang === "en") return null;
    const idx = lang === "ru" ? 0 : 1;
    if (Object.prototype.hasOwnProperty.call(D, text)) return D[text][idx];
    for (const [re, out] of P) {
      const m = text.match(re);
      if (m) return out[lang].replace(/([~$])(\d)/g, (_, k, i) => (k === "~" ? tr(m[i]) || m[i] : m[i]));
    }
    return null;
  }

  const SKIP = new Set(["SCRIPT", "STYLE", "CODE", "TEXTAREA", "INPUT"]);
  const ATTRS = ["aria-label", "title", "placeholder"];

  function textNode(node) {
    const raw = node.nodeValue;
    const core = raw.trim();
    if (!core || !/[A-Za-z]/.test(core)) return;
    const p = node.parentNode;
    if (p && SKIP.has(p.nodeName)) return;
    const out = tr(core);
    if (out != null && out !== core) node.nodeValue = raw.replace(core, out);
  }

  function attrs(el) {
    for (const a of ATTRS) {
      const v = el.getAttribute && el.getAttribute(a);
      if (!v) continue;
      const out = tr(v.trim());
      if (out != null && out !== v) el.setAttribute(a, out);
    }
  }

  function walk(root) {
    if (root.nodeType === 3) return textNode(root);
    if (root.nodeType !== 1) return;
    attrs(root);
    if (SKIP.has(root.nodeName)) return;
    const it = document.createTreeWalker(root, NodeFilter.SHOW_ELEMENT | NodeFilter.SHOW_TEXT);
    let n;
    while ((n = it.nextNode())) {
      if (n.nodeType === 3) textNode(n);
      else attrs(n);
    }
  }

  function start() {
    document.documentElement.lang = lang;
    const sel = document.getElementById("lang");
    if (sel) {
      sel.replaceChildren(...SUPPORTED.map(code => {
        const o = document.createElement("option");
        o.value = code;
        o.textContent = NAMES[code];
        o.selected = code === lang;
        return o;
      }));
      sel.addEventListener("change", () => {
        try { localStorage.setItem(KEY, sel.value); } catch (e) {}
        location.reload();
      });
    }
    if (lang === "en") return;
    const titled = tr(document.title);
    if (titled) document.title = titled;
    walk(document.body);
    new MutationObserver(list => {
      for (const m of list) {
        if (m.type === "characterData") textNode(m.target);
        else if (m.type === "attributes") attrs(m.target);
        else m.addedNodes.forEach(walk);
      }
    }).observe(document.body, { subtree: true, childList: true, characterData: true, attributes: true, attributeFilter: ATTRS });
  }

  window.PyI18n = { lang, locale: LOCALES[lang], tr };
  if (document.readyState === "loading") document.addEventListener("DOMContentLoaded", start);
  else start();
})();
