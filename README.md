# YMusic — клиент Яндекс.Музыки (iOS 15.3, SwiftUI)

Личный клиент для собственного аккаунта. Без App Store, установка через TrollStore.

## Статус

| Фаза | Статус |
|------|--------|
| 0. Каркас проекта, сетевой слой, Keychain | готово |
| 1. OAuth через `ASWebAuthenticationSession`, `LoginView` | готово |
| 2. Liquid Glass, `DynamicBackground`, `MainView` | готово |
| 3. Каталог: плейлисты и лайки, живые обложки | готово (частично, см. TODO) |
| 4. Плеер: AVPlayer, очередь, mini + full, пагинация лайков | готово (см. «Как воспроизводится звук») |
| 5. Системная интеграция плеера, лайки, «Мне нравится», плейлист, сохранение состояния | готово (см. TODO по хвостам) |
| 6. Поиск и «Моя волна» (rotor), троттлинг состояния | готово (см. TODO по хвостам) |
| 7. Plus-обход | **не реализуется** (см. «Ограничения») |
| 8. Сборка .ipa для TrollStore | ожидает |

## Структура

```
y.music/
├── project.yml                       # XcodeGen: генерация .xcodeproj
├── README.md
└── YMusic/
    ├── App/
    │   ├── YMusicApp.swift           # @main + RootView (переключение сессии)
    │   └── AppEnvironment.swift      # DI-корень
    ├── DesignSystem/
    │   ├── Glass.swift               # GlassCard/Button/Header/Chip, ContentTone, LiquidBackdrop
    │   └── DynamicBackground.swift   # фон из палитры обложки + скрим
    ├── Features/
    │   ├── Auth/LoginView.swift      # экран входа
    │   ├── Catalog/
    │   │   ├── CatalogView.swift     # секции каталога, карточки, ошибки
    │   │   └── CatalogViewModel.swift
    │   ├── Library/
    │   │   ├── LikedTracksView.swift # полный список «Мне нравится»
    │   │   ├── LikedTracksViewModel.swift
    │   │   ├── PlaylistDetailView.swift
    │   │   └── PlaylistDetailViewModel.swift
    │   ├── Search/
    │   │   ├── SearchView.swift      # стеклянный search-bar, история, секции
    │   │   └── SearchViewModel.swift # дебаунс 300 мс, отмена, история
    │   ├── Player/
    │   │   ├── MiniPlayerView.swift  # полоса над нижним краем
    │   │   ├── NowPlayingView.swift  # полноэкранный плеер
    │   │   └── LikeButton.swift      # сердечко + тактильный отклик
    │   ├── Shared/
    │   │   └── TrackRowView.swift    # общая строка трека (каталог/лайки/плейлист/поиск)
    │   ├── Main/
    │   │   ├── MainView.swift        # главный экран, экраны-модалки, «Моя волна»
    │   │   └── WaveViewModel.swift   # загрузка треков «Моей волны»
    ├── Core/
    │   ├── API/                      # MusicCatalogProviding, YandexMusicCatalog,
    │   │                             # AudioStreamProviding, LikesProviding,
    │   │                             # SearchProviding/YandexSearchProvider,
    │   │                             # RotorProviding/YandexRotorProvider
    │   ├── Audio/
    │   │   ├── AudioPlayer.swift     # AVPlayer, очередь, аудиосессия, прерывания
    │   │   ├── NowPlayingCenter.swift# MPNowPlayingInfoCenter + MPRemoteCommandCenter
    │   │   ├── PlaybackQueue.swift   # shuffle/repeat, next/previous
    │   │   ├── LikeStore.swift       # оптимистичные лайки
    │   │   ├── YandexAudioStreamProvider.swift # download-info → XML → прямая ссылка
    │   │   ├── YandexDirectLink.swift
    │   │   └── BundledDemoStreamProvider.swift # только для проверки UI
    │   ├── Persistence/
    │   │   ├── PlaybackStateStore.swift # очередь/«Недавнее» в UserDefaults по userID
    │   │   └── SearchHistoryStore.swift # последние 10 запросов по userID
    │   ├── Image/
    │   │   ├── ColorExtractor.swift  # actor: CIAreaAverage, кэш палитр
    │   │   └── ImageLoader.swift     # NSCache + CachedAsyncImage
    │   ├── Networking/               # Endpoint, APIClient (actor), APIError
    │   ├── Auth/
    │   │   ├── AuthConfig.swift      # client_id официального клиента + URL согласия
    │   │   ├── AuthService.swift     # состояние сессии, сохранение токена
    │   │   ├── KeychainStore.swift
    │   │   └── TokenStore.swift      # хранение токена (без refresh)
    │   ├── Services/APIManager.swift
    │   └── Models/
    └── Resources/
        └── Info.plist                # генерируется XcodeGen
```

## Что осталось в TODO

- **`/landing3`** (блоки главной: новинки, подборки, чарты) — не реализовано.
  Схема `content.blocks[].entities[].data` нестабильна, нужен живой JSON
  для сверки, иначе парсер молча отдаёт пустоту.
- **`/rotor/station/user:onyourwave/tracks`** («Моя волна») — реализовано
  и проверено на живом API (200). Схема сверена с
  `MarshalX/yandex-music-api` (`StationTracksResult`/`Sequence`):
  берём элементы `type == "track"`. Заголовок
  `X-Yandex-Music-Client` вынесен в константу `YandexRotorProvider.clientHeaderValue`
  (`YandexMusicAndroid/24023621`). Пустая волна трактуется как ошибка,
  а не как «нет рекомендаций».
- **Лайк/анлайк** — подключены к UI (`LikeStore`, сердечко в строке и
  в плеере). Ручки сверены с `MarshalX/yandex-music-api`:
  `POST /users/{uid}/likes/tracks/add-multiple` и
  `POST /users/{uid}/likes/tracks/remove`, тело — form `track-ids`
  (`trackId:albumId`). Кэш id в каталоге сбрасывается после успеха.
- **Воспроизведение плейлиста** — карточка открывает `PlaylistDetailView`,
  «Играть всё» запускает очередь. Если сервер вернул меньше треков, чем
  `trackCount`, экран честно пишет «Показаны первые N из M»; догрузки по
  `track-positions` пока нет.
- **Поиск** — реализован (`GET /search?text=…&type=all`): дебаунс 300 мс,
  отмена предыдущего запроса, история последних 10 запросов в `UserDefaults`
  по `userID`. Тап по артисту/альбому — TODO (экраны Фазы 7), плейлист
  открывается как в Фазе 5.
- **Полный список лайков** — пагинация сделана (`likedPage`),
  отдельный экран «Мне нравится» (`LikedTracksView`) использует её же.
  `/likes/tracks` отдаёт только id: каждая страница — это ещё один запрос
  в `/tracks`. Кэш id живёт в памяти актора и сбрасывается при перезапуске.
- **Откат состояния** — `AudioPlayer` не хранит громкость в `MPVolumeView`,
  только `AVPlayer.volume`; системная громкость приложению недоступна.

## Как воспроизводится звук

1. `GET /tracks/{id}/download-info` (id — `trackId` или `trackId:albumId`).
   Сервер сам решает, какие варианты доступны аккаунту.
2. Если `direct == false`, скачивается XML по `downloadInfoUrl`:
   `host` / `path` / `ts` / `s`.
3. Прямая ссылка: `https://{host}/get-mp3/{md5(salt + path[1:] + s)}/{ts}{path}`.
   Это обычный MP3/AAC по HTTPS — `AVPlayer` играет его напрямую, без
   AES и без ключей. Ссылка живёт около минуты, поэтому разрешается
   непосредственно перед запуском.
4. Если сервер вернул только `preview: true` — играет 30-секундный фрагмент
   и в UI честно написано «превью».
5. Если не вернулось ничего — `APIError.unavailable`, в плеере карточка
   «Требуется подписка». Обхода нет: право проверяет сервер.

## Системная интеграция плеера

- **Локскрин / Control Center / AirPods / CarPlay-кнопки** —
  `NowPlayingCenter` (обёртка над `MPNowPlayingInfoCenter` и
  `MPRemoteCommandCenter`). Обложка берётся из `ImageLoader.cachedImage`,
  если её нет — догружается и публикуется вторым обновлением.
- **Команды пульта**: play/pause/toggle/next/previous/seek/rate. Когда
  очередь пуста — команды выключаются, а `nowPlayingInfo` очищается.
- **Прерывания** (`AVAudioSession.interruptionNotification`): на `.began`
  запоминаем, играли ли, и ставим паузу; на `.ended` с `.shouldResume`
  возобновляем, только если пауза пришла не от пользователя.
- **Выдёргивание наушников** (`routeChangeNotification`,
  `.oldDeviceUnavailable`) — пауза без автовозобновления.
- **Фон** — `UIBackgroundModes: [audio]` в `project.yml`. В фоне плеер
  продолжает играть; обложки из фона не догружаются.
- **teardown** снимает time-observer, KVO по `AVPlayerItem`, notification-
  наблюдатели, remote-таргеты и деактивирует сессию. Вызывается из `stop()`
  и из `RootView` при `.inactive` с пустой очередью; в `deinit` остаётся
  только отмена задачи загрузки.
- **Троттлинг**: `UserDefaults` и `nowPlayingInfo` обновляются не на каждом
  тике 0.5 с, а на переходах (prepare/play/pause), на seek и раз в 30 с
  (счётчик тиков `checkpointTicks`). Прогресс на локскрине система считает
  сама по `playbackRate`.
- **Возврат из фона**: `RootView` на `.active` вызывает
  `reinstallRemoteIfNeeded()` — после `teardown()` remote-таргеты и команды
  ставятся заново.

## Поиск и «Моя волна»

- **Поиск** (`SearchView`, `SearchViewModel`): свой стеклянный search-bar
  (`.searchable` на iOS 15 не подходит), дебаунс 300 мс через `Task.sleep`,
  отмена предыдущего запроса, история 10 запросов (`SearchHistoryStore`,
  ключ по `userID`). Секции `tracks/artists/albums/playlists`; трек и
  плейлист открываются, артист/альбом — TODO Фазы 7.
- **«Моя волна»** (`WaveViewModel`, `YandexRotorProvider`):
  `GET /rotor/station/user:onyourwave/tracks?settings2=true`. Карточка на
  главном показывает до 5 треков и «Играть всё»; при ошибке — причина и
  «Повторить», а не выдуманная подборка.

## Состояние между запусками

- `PlaybackStateStore` (UserDefaults, ключ на `userID`): очередь, позиция,
  shuffle, repeat, `AVPlayer.volume` и последние 20 треков («Недавнее»).
- При старте очередь восстанавливается **на паузе**, без автоплея.
- «Недавнее» показывается на главном, пока каталог грузится.
- Выход из аккаунта очищает состояние этого `userID`.

## Вход в аккаунт

Приложение входит через **клиент официального приложения «Яндекс.Музыка»**
(`client_id` в `AuthConfig.swift`) — это не секрет, его используют все
сторонние клиенты. Собственное OAuth-приложение не подходит: Яндекс не
выдаёт сторонним приложениям право `music:content`, и внутренний API
отвечает `403 missing-required-scopes` (проверено на живом сервере).

Поток:

1. `YandexLoginView` открывает `https://oauth.yandex.ru/authorize?response_type=token&client_id=...`
   в `WKWebView` (не Safari: редирект у клиента `https`-овый, а не `ymusic://`).
2. Пользователь подтверждает доступ на странице Яндекс ID.
3. Яндекс уводит на `https://music.yandex.ru/#access_token=...`; навигацию
   перехватывает делегат web-view, токен попадает в Keychain.
4. `GET /account/status` проверяет токен и отдаёт числовой `uid`.

Implicit-токен живёт около года и не имеет `refresh_token`: когда истечёт,
приложение попросит войти снова. Cookies Яндекс ID сохраняются между
запусками, поэтому повторный вход обычно без пароля.

## Сборка

Нужен macOS + Xcode 14+.

```bash
brew install xcodegen
xcodegen generate
open YMusic.xcodeproj
```

## Как проходит вход

1. Тап «Войти через Яндекс» → `ASWebAuthenticationSession` открывает системный Safari
   (не `WKWebView`: Яндекс видит обычный браузер, cookies Safari переиспользуются).
2. Пользователь вводит логин/пароль на `oauth.yandex.ru`.
3. Яндекс редиректит на `ymusic://oauth#access_token=...&expires_in=...`.
   Токен лежит в **фрагменте**, поэтому разбираем `fragment`, а не `queryItems`.
4. Токен пишется в Keychain (`kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`).
5. `GET /account/about` подтверждает сессию → `RootView` показывает главный экран.
6. Закрытие окна браузера = `ASWebAuthenticationSessionError.canceledLogin`,
   экран логина остаётся на месте без сообщения об ошибке.

Токен из implicit flow не содержит `refresh_token`: когда истечёт срок жизни,
сервер ответит 401, `TokenStore.refresh()` бросит `unauthorized`, и приложение
вернёт пользователя на `LoginView` с сообщением «Сессия истекла».

## Ограничения

- API `api.music.yandex.net` неофициальный; использование сторонним клиентом
  нарушает пользовательское соглашение — есть риск ограничения аккаунта.
- Клиент работает только с правами, которые выдаёт сервер для вашего аккаунта.
