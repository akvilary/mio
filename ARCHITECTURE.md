# MIO (Swift) — архитектура и схема операций

Этот документ — полное описание того, как устроен пакет `mio`: какие есть
слои и типы, кто чем владеет, как протекают операции (регистрация, ожидание,
пробуждение), и почему принято каждое ключевое решение. Рассчитан на
чтение «с нуля»: понимание epoll не требуется — нужные детали ядра
объясняются по ходу.

Оригинал для сравнения — [mio (Rust)](https://github.com/tokio-rs/mio),
версия 1.x. Наш порт повторяет его модель, где сознательно отходит —
перечислено в §11.

---

## 1. Что это такое — и чем не является

MIO — это **тонкий слой готовности (readiness) поверх epoll(7)**. Он
отвечает ровно на два вопроса:

1. *Какие источники (fd) сейчас готовы к чтению/записи?* — `Poll` / `Events`.
2. *Как разбудить ожидающий поток из другого потока?* — `Waker`.

MIO **не** содержит: событийный цикл, executor/шедулер, async/await,
буферизованный I/O, работу с сокетами. Всё это строят слои выше — у нас
это `pulsar` (аналог tokio-runtime: `PollEventLoop`, акторы, дедлайны) и
`starlight` (аналог axum: HTTP-сервер). MIO — субстрат, на котором они
стоят. Аналогия из Rust: tokio → mio → epoll. У нас: starlight → pulsar →
mio → epoll.

---

## 2. Модель readiness: что сообщает ядро

`epoll` — это очереди готовности в ядре. Регистрация fd в epoll означает:
«сообщи мне, когда на этом fd появится интересующее событие». Проверка
готовности (`read`/`write`) остаётся за вызывающим — epoll только
*сигнализирует*.

Два режима срабатывания:

| Режим | Когда приходит событие | Контракт для вызывающего |
|---|---|---|
| **LT** (level-triggered, наш дефолт) | пока условие держится — событие повторяется на каждом `epoll_wait` | достаточно reacting; забытое чтение = событие придёт снова |
| **ET** (edge-triggered, `.edge`) | только в момент перехода «не готов → готов» | **обязан** вычитывать/записывать до `EAGAIN` |

mio (Rust) регистрирует всё в ET и возлагает дисциплину
«drain-until-EAGAIN» на вызывающего. Мы по умолчанию даём LT — это
безопаснее для самописных циклов (событие не потеряется) — а ET даём как
опцию per-регистрации (`Interest.edge`). Это главное сознательное
расхождение, см. §11.

Ключевые биты, которые ядро может прислать в событии:

| Бит | Константа | Значение |
|---|---|---|
| `IN`    | 0x001 | есть данные (или EOF: read вернёт 0) |
| `PRI`   | 0x002 | out-of-band/urgent данные |
| `OUT`   | 0x004 | можно писать |
| `ERR`   | 0x008 | ошибка на fd (приходит всегда, независимо от интереса) |
| `HUP`   | 0x010 | обе стороны закрыты (тоже всегда) |
| `RDHUP` | 0x2000 | пир закрыл свою сторону записи (half-close) — **приходит только если его запрошали** |

`ERR` и `HUP` ядро добавляет всегда; остальные — только из маски интереса
регистрации. Поэтому мы автоматически добавляем `RDHUP` к `.readable`
(см. §7.2) — иначе half-close неотличим от обычной читаемости.

---

## 3. Карта типов

| Тип | Вид | Роль | Владеет | Аналог в mio (Rust) |
|---|---|---|---|---|
| `Registry` | final class | ARC-владелец epoll fd; поверхность регистрации | **epoll fd** (close в `deinit`) | `Registry` + `OwnedFd` |
| `Poll` | struct | лёгкая обёртка над `Registry`; точка входа ожидания | — (удерживает `registry`) | `Poll` (тоже value-подобный) |
| `Events` | `~Copyable` struct | переиспользуемый буфер событий, куда пишет ядро | raw-буфер `sl_epoll_event` | `Events` (Vec) |
| `Event` | frozen struct | одно событие: `token` + `ready` | — | `Event` |
| `Interest` | OptionSet\<u32\> | что хотим отслеживать при регистрации | — | `Interest` (NonZeroU8) |
| `Ready` | OptionSet\<u32\> | что ядро сообщило | — | `EventFlags` |
| `Token` | struct | пользовательский id (u64), ядро возвращает его в событии | — | `Token(usize)` |
| `Waker` | final class | кросс-поточное пробуждение через eventfd | **eventfd** (close в `deinit`) | `Waker` (File внутри) |
| `PollTimeout` | struct | таймаут ожидания (ms + ns-компонента) | — | `Option<Duration>` |
| `PollError` | struct | errno + имя syscall'а | — | `io::Error` |
| `TimerFd` | enum (namespace) | периодический timerfd | — (голый fd у вызывающего) | — (нет в mio) |
| `PollSource` | protocol | «у меня есть fd» + дефолтные register/... | — | `event::Source` |

Слоёв два:

```
┌───────────────────────────────────────────────────────────────┐
│  MIO (Swift):  Poll, Registry, Events, Waker, Interest, ...   │
│                 типы, ARC-владение, Sendable-модель           │
├───────────────────────────────────────────────────────────────┤
│  CMIO (C):     sl_epoll_*, sl_eventfd, sl_timerfd_*           │
│                 конвенция «fd или -errno», packed-структура    │
├───────────────────────────────────────────────────────────────┤
│  Ядро Linux:   epoll(7), eventfd(2), timerfd(2)               │
└───────────────────────────────────────────────────────────────┘
```

C-слой существует потому, что Glibc-модуль Swift не экспортирует
`<sys/epoll.h>` / `<sys/timerfd.h>` (плюс ещё две причины — packed-ABI и
гарантия errno). Полный разбор с проверяемыми фактами — в
[WHY_C_LAYER.md](WHY_C_LAYER.md). Конвенция C-обёрток: успех = `fd ≥ 0`
или `0`, ошибка = `-errno` — errno снимается в C немедленно после
syscall'а, до того как рантайм Swift успеет его затереть (гонка, которая
была бы возможна при чтении `errno` из Swift).

`sl_epoll_event` — 12-байтовая packed-копия `struct epoll_event`
(`events: UInt32` + `data: UInt64`); в `data` ездит `Token.raw`.

---

## 4. Владение и время жизни (ARC-модель)

Это самое важное архитектурное решение порта. В Rust mio время жизни
epoll fd держит `OwnedFd` (закрытие при drop), а `Registry::try_clone`
делает `dup(2)`. В Swift роль `OwnedFd` играет **счётчик ссылок класса
`Registry`**:

```
        Poll (struct)          Waker (class)         любые хэндлы
             │                      │                     │
             └──────────┬───────────┴─────────────────────┘
                        ▼  retain (+1 каждый)
              ┌───────────────────┐
              │ Registry (class)  │   refcount = число удерживающих
              │  _epfd: CInt      │
              └───────────────────┘
                        │  последний release (refcount → 0)
                        ▼
              deinit: close(_epfd)      ← ядро атомарно снимает
                                        ВСЕ регистрации этого epoll
```

Следствия:

- **Одна** куча-аллокация на инстанс (сам `Registry`); `Poll` — struct,
  копирование стоит retain/release (~2 nonatomic-операции).
- Контракт «держите `Poll` живым, иначе EBADF» **исчез** — его заменил
  ARC: пока жива любая ссылка на `registry`, fd открыт. Уронить use-after-
  close на этом уровне невозможно.
- `Poll.registry` — единственный способ получить `Registry` (init у
  `Registry` internal), как в mio, где `Registry` раздаёт только `Poll`.
- `Registry == / hash` — по **идентичности объекта** (`===`), не по номеру
  fd: номер ядро переиспользует после закрытия, сравнение по нему
  отождествило бы разные epoll-инстансы.

`Events` — move-only (`~Copyable`) с собственным `deinit`: буфер живёт
столько же, сколько значение; компилятор гарантирует единственного
владельца. `Waker` владеет eventfd и закрывает его в `deinit`; при этом
`Waker` **не** удерживает `Registry` (как и в mio, где Waker не держит
селектор): если все ссылки на registry умерли, pending-пробуждения просто
никем не наблюдаются, а `wake()` остаётся безвредным.

---

## 5. Потоковая модель

- `Poll`, `Registry`, `Waker`, `Event`, `Interest`, `Ready`, `Token`,
  `PollTimeout`, `PollError` — `Sendable` **структурно** (immutable `let`,
  компилятор проверяет без `@unchecked`).
- Синхронизация состояния — **в ядре**: `epoll_ctl` и `epoll_wait`
  потокобезопасны сами по себе (epoll(7)). Реалистичный шаблон — один
  поток-луп на `Poll`, кросс-поточная регистрация при необходимости.
- `Events` — **намеренно не Sendable**: `Poll.poll` мутирует `_count` на
  вызывающем потоке. Один `Events` на поток-воркер.
- Замков в библиотеке нет вообще. Единственная разделяемая атомика —
  `Poll.pwait2Unavailable` (процесс-шид кэш «epoll_pwait2 нет»), плюс
  debug-only `Atomic<Bool>` в Registry (правило одного Waker, §7.4).

---

## 6. Схема: типичный цикл событий

Сначала общая картина — как куски сходятся в рантайме (pulsar это и
реализует):

```
 поток-луп                                       прочие потоки / задачи
 ─────────────────────────────────────           ──────────────────────────
 let poll = try Poll()
 let waker = try Waker(registry: poll.registry,
                       token: .wakeup)            waker.wake()        ─┐
 var events = Events(capacity: 1024)             (из любого потока)   │
 loop {                                                               │
   // 1. ждать (блокирующий syscall)                                  │
   n = try events.wait(on: poll,                                             │
                 timeout: .blocking)  ◄──── readable на Token.wakeup ──────┘
   // 2. разобрать события
   events.forEach { ev in
     switch ev.token {
       case .wakeup: waker.reset()      // слить счётчик eventfd → 0
                     //    + проверить флаги/очередь причин пробуждения
       default:       dispatch(ev.token, ev.ready)   // данные на каналах
     }
   }
 }   // событий нет → снова блок в epoll_wait; цикл не крутится вхолостую
```

Дальше — каждая операция по шагам.

### 6.1 Создание `Poll`

```
Poll()  →  Registry()  →  sl_epoll_create1()      [C]
                          epoll_create1(EPOLL_CLOEXEC)
                          return fd | -errno
```

`EPOLL_CLOEXEC` — fd не утекает в дочерние процессы после exec. Ошибка
(например, `EMFILE` при исчерпании fd) → `PollError(code:function:)`,
инстанс не создаётся вовсе.

### 6.2 Регистрация источника

```
registry.register(fd, token, interest)
   │
   ├─ interest._epollBits            [Swift]
   │    rawValue
   │    + RDHUP, если .readable и НЕ .exclusive   ← mio-parity,
   │                                                см. §7.2
   ├─ (debug) assert: не (.exclusive && .edge)    ← EINVAL ядра
   └─ sl_epoll_ctl_add(epfd, fd, bits, token.raw) [C]
        → 0 | -errno                                (EEXIST если уже есть)
```

- `reregister` — то же через `EPOLL_CTL_MOD`: смена токена/интереса,
  перезарядка oneshot. NB: `.exclusive` нельзя добавить через reregister
  (ядро молча игнорирует — только при ADD).
- `deregister` — `EPOLL_CTL_DEL`; `tryDeregister` — то же, но `ENOENT`
  возвращается как `false`, а не throw (для cleanup-путей).
- **Важно**: если вы владеете fd и собираетесь его `close(2)` — deregister
  не нужен: закрытие атомарно снимает регистрацию со всех epoll-инстансов.

### 6.3 Ожидание: `Events.wait(on:timeout:)`

```
events.wait(on: poll, timeout:)
   loop {
     n = sl_epoll_wait(epfd, events._rawBuffer, capacity, ms)   [C]
       n ≥ 0  → _count = n; return n        (0 = таймаут)
       EINTR  → continue                     (ретрай, см. оговорку ниже)
       прочее → _count = 0; throw PollError
   }
```

Свойства:

- Ядро пишет **прямо в наш буфер** — ноль аллокаций на вызов; `Event`-
  структуры материализуются как значения только при обходе (`forEach`/
  `subscript`) и остаются регистровыми.
- Таймаут: `.blocking` → −1 (навсегда), `.immediate` → 0, `.milliseconds`
  → ms. У `.nanoseconds` ms-компонента = округление **вверх** (вызывающий
  никогда не недождёт), а точное ns-значение едет в pwait2 (§6.4).
- **Оговорка EINTR**: ретрай перезапускает ожидание с *полным исходным*
  таймаутом — время, проведённое в блоке до сигнала, не вычитается.
  mio (Rust) вместо этого возвращает `Interrupted` вызывающему. Для
  точных дедлайнов — `.immediate` + свой таймер. Это документированное
  расхождение.

### 6.4 Наносекунды: `waitNano` и `epoll_pwait2`

```
waitNano(on:timeout:sigmask:)
   ├─ Poll.pwait2Unavailable == true?                [Atomic, process-wide]
   │     да  → обычный wait с ms-компонентой (fallback)
   └─ нет → loop {
        n = sl_epoll_pwait2(epfd, buf, cap, sec, nsec, sigmask)
          n ≥ 0   → return n
          EINTR   → continue
          ENOSYS  → pwait2Unavailable.store(true)    ← ласкающийся кэш:
                    → fallback к epoll_wait             одна неудачная
                    попытка на процесс, дальше — ветка
          прочее  → throw
      }
```

Две детали C-слоя, обе выучены на реальных багах:

1. **Блокировка навсегда = NULL-timespec.** Ядро отвергает timespec с
   отрицательным `tv_sec` (`EINVAL`) — «навсегда» выражается только
   NULL-указателем. C-обёртка делает это сама при `sec < 0`.
2. `sigsetsize` в glibc-обёртке не параметризован (внутри
   `sizeof(sigset_t)`) — параметр оставлен для совместимости с raw
   syscall.

Семантика sigmask — как у `pselect`: маска **атомарно** ставится на время
ожидания и восстанавливается на выходе. Никакой гонки «проверил флаг →
начал ждать → сигнал пришёл между». Устройство маски не блокирует уже
pending-сигналы: заблокированный до вызова и разблокированный маской
сигнал доставляется прямо на входе в ожидание (на этом построен
детерминированный тест EINTR). Nuance: если события **уже готовы**,
syscall вернёт их без установки маски (fast-path) — маску нельзя считать
«побочным эффектом», она гарантируется только при реальном блоке.

### 6.5 Чтение событий

```
events.forEach { event in ... }     // borrowing, @inlinable
events[0]                            // precondition 0..<count
events.toArray()                     // аллокация — только для тестов/логов
```

Предикаты `Event`/`Ready` повторяют mio 1:1:

```
isReadable    = IN || PRI                  // OOB считается читаемостью
isReadClosed  = HUP || (IN && RDHUP)       // см. §7.2
isWriteClosed = HUP || (OUT && ERR) || raw == ERR
isWritable / isError / isHangup — прямые биты
```

---

## 7. Специальные сценарии

### 7.1 Waker: кросс-поточное пробуждение

Реализация — eventfd, это 64-битный счётчик в ядре: `write(8 байт)`
прибавляет, `read(8 байт)` атомарно забирает значение и обнуляет.

```
 создание:  Waker(registry:token:)
              fd = eventfd(0, EFD_NONBLOCK | EFD_CLOEXEC)   // БЕЗ semaphore
              registry.register(fd, token, .readable)        // level-triggered

 пробуждение (любой поток):              дрейн (поток-луп):
   wake()                                  reset()
     write(fd, 1)                            read(fd) → счётчик, → 0
     EINTR → повтор                          EAGAIN (было 0) → молча 0
     EAGAIN (счётчик полон                   EINTR → повтор
       UINT64_MAX-1) → true                  результат = сколько пробуждений
     EBADF/EINVAL → false                    слилось в один дрейн
```

Свойства и правила:

- **Слитие пробуждений — фича**: N вызовов `wake()` до дрейна = один
  readable-событие; `reset()` вернёт, сколько их было. Это и нужно лупу:
  проснулся → слил → проверил все причины.
- Регистрация **LT**: пока счётчик не слит, токен будет прилетать на
  каждом wait. Поэтому дрейн обязателен — иначе луп заспинится на
  вечно-готовом токене.
- **Один Waker на Registry** (debug-ассерт, mio parity). Причина — не
  «нельзя», а «опасно»: два waker'а на одном токене (а `Token.wakeup = 0`
  — конвенция!) делают описанный выше вечный спин: луп дрейнит свой fd,
  чужой остаётся готовым навсегда. Канонический паттерн — **один waker +
  атомики/очередь причин**: выставил флаг → `wake()` → луп после пробуждения
  проверяет флаги (tokio-стиль). Ассерт не сбрасывается после смерти
  waker'а: waker — объект времени жизни лупа.
- Waker не продлевает жизнь Registry (§4).

### 7.2 Half-close: авто-EPOLLRDHUP

Проблема: пир вызвал `shutdown(SHUT_WR)` (или закрыл соединение,
записав всё). Ядро помечает rx-очередь `IN|RDHUP`, **но RDHUP приходит
только если он был в маске интереса**. Без него событие выглядит как
обычная читаемость — и EOF узнаётся только дотейкав `read() == 0`.

Решение (mio parity): `_epollBits` добавляет RDHUP ко всем `.readable`
регистрациям. Тогда:

```
пир: write("x"); shutdown(SHUT_WR)
       │
       ▼
событие: IN|RDHUP → isReadable = true, isReadClosed = true
       │
       ▼
луп: read → "x" (данные), read → 0 (EOF)   — оба шага штатные
```

Исключение: `.exclusive`. Whitelist ядра для `EPOLLEXCLUSIVE` — строго
`IN|OUT`; добавление RDHUP валит весь `epoll_ctl` с `EINVAL`. Для
shared-listener'ов (главный кейс exclusive) half-close всё равно не
бывает, так что бит просто подавляется.

### 7.3 Таймеры: `TimerFd`

```
TimerFd.create()                  → timerfd(CLOCK_MONOTONIC, NONBLOCK|CLOEXEC)
TimerFd.setPeriodic(fd, interval) → it_value = it_interval = interval
TimerFd.setPeriodic(fd, .zero)    → disarm
```

Периодический: первое срабатывание через `interval`, далее каждое.
Регистрируется как обычный источник (`.readable`), дрейн — 8-байтовый
`read`. Использование — «сердцебиение» реактора для сверки дедлайнов
(pulsar так и делает). Одноразовых таймеров нет (в mio их тоже нет —
расширение при необходимости).

### 7.4 `PollSource` — интеграция своих типов

```swift
public protocol PollSource: Sendable {
    var pollSourceFD: CInt { get }
    // register/reregister/deregister — дефолты зовут Registry
}
```

Идиома для классов-обёрток над fd: соответствуешь протоколу — тебя можно
регистрировать типизированно. В mio то же самое делает `event::Source`
(там через trait-объекты; у нас протокол с дефолтными реализациями).

---

## 8. Производительность: счёт затрат

| Что | Когда | Стоимость |
|---|---|---|
| `Poll()` | раз на луп | 1 куча-аллокация (`Registry`) + 1 syscall |
| `Events(capacity:)` | раз на поток | 1 аллокация буфера (12 байт × capacity), занулённая |
| `Waker(...)` | раз на луп | 1 аллокация + eventfd + регистрация |
| `wait(...)` за вызов | на итерацию лупа | 0 аллокаций: retain/release `Registry` (~2 nonatomic) + syscall |
| обход событий | на итерацию | 0 аллокаций: `Event` — значение, `forEach` `@inlinable` |
| `register/reregister` | на канал/перезарядку | 1 syscall, 0 аллокаций |
| `wake()` | на пробуждение | 1 syscall (`write`), 0 аллокаций |
| локи | — | нет; 1 процесс-шид атомика (кэш pwait2) |

Горячий путь (`wait` + обход) не аллоцирует и не локается. `PollError`
несёт `StaticString` — throw тоже без аллокаций.

Замеры (starlight hello-world, wrk, A/B против mio-Rust-эквивалентной
структуры) — в `../starlight/bench/results/MIO_restructuring.md`:
паритет ±1% с оригинальной структурой до реструктуризации.

---

## 9. Ошибки

```swift
PollError(code: errno, function: "epoll_wait")   // errno > 0, StaticString
PollError.fromNegativeReturn(rc, function:)      // из -errno C-обёрток
PollError.fromErrno(function:)                   // fragile: errno мог затереться
```

Правило порта: **все** ошибки идут через `fromNegativeReturn`/прямой
`code:` — errno снимается в C атомарно результату. `fromErrno` оставлен
для чужих syscall'ов, вызываемых прямо из Swift.

---

## 10. Порядок чтения исходников

Читать в этом порядке — каждый файл опирается на предыдущие:

1. `Sources/CMIO/include/CMIO.h` — контракты C-слоя и конвенция −errno.
2. `Sources/MIO/Token.swift`, `Interest.swift`, `Ready.swift` —
   словарь бит и токенов.
3. `Sources/MIO/Poll.swift` — `PollTimeout`, `Poll`, `Registry`
   (владение — в комментариях).
4. `Sources/MIO/Events.swift` — `Event`, `Events` (+ `wait`/`waitNano`).
5. `Sources/MIO/Waker.swift` — пробуждение.
6. `Sources/MIO/PollError.swift`, `PollConstants.swift`, `TimerFd.swift`,
   `Source.swift` — обвязка.
7. `Tests/MIOTests/PollTests.swift` — исполняемая спецификация контрактов
   (30 тестов: lifecycle, LT/ET, oneshot, exclusive, half-close, EINTR,
   сатурация таймаутов, lifetime Registry...).

---

## 11. Сравнение с mio (Rust): паритет и расхождения

**Паритет 1:1**: поверхность API (Poll/Registry/Token/Interest/Event/
Events/Waker/Source); маппинг интересов c авто-RDHUP; формулы
readiness-предикатов; округление таймаутов вверх; сатурация ms-диапазона;
правило одного Waker (debug); EFD-флаги и семантика write/read.

**Сознательные расхождения** (все задокументированы в коде):

| Тема | mio (Rust) | Мы | Почему |
|---|---|---|---|
| Триггер | всегда ET | LT по умолчанию, `.edge` опционально | безопаснее для самописных лупов; ET — оптимально только при дисциплине drain |
| Lifetime селектора | `OwnedFd` + `dup(2)` в `try_clone` | ARC на `Registry` | та же гарантия без syscall и второй аллокации |
| EINTR в poll | наружу (`Interrupted`) | автоматический ретрай | эргономика; таймаут перезапускается целиком — caveat задокументирован |
| Точность таймаута | только ms | + ns (`epoll_pwait2`, 5.11+) с ENOSYS-fallback | расширение; на старых ядрах деградация до ms-округления вверх |
| `Waker.wake()` | `io::Result<()>`, при WouldBlock — reset+повтор записи | `Bool`, EAGAIN → `true` | при LT-регистрации насыщенный счётчик уже означает доставленное пробуждение |
| `.oneshot`/`.exclusive` | нет | есть | нужны реактору (перезарядка) и shared-listener кейсам |
| `TimerFd` | нет | есть | heartbeat для сверки дедлайнов в pulsar |
| `Events` | `Vec` (Sendable) | `~Copyable`, не Sendable | компилятор доказывает контракт «один владелец — один поток» |

---

## 12. Канонические паттерны использования

### Скелет однопоточного лупа (мультиплексирование причин через один waker)

```swift
let poll = try Poll()
let waker = try Waker(registry: poll.registry, token: .wakeup)
var events = Events(capacity: 1024)

// кросс-поточная причина пробуждения — флаг, не второй waker:
let shutdownRequested = Atomic<Bool>(false)
// из любого потока:  shutdownRequested.store(true, .releasing); waker.wake()

loop: while !shutdownRequested.load(ordering: .acquiring) {
    _ = try events.wait(on: poll, timeout: .blocking)
    events.forEach { ev in
        switch ev.token {
        case .wakeup:
            _ = waker.reset()          // слить счётчик — обязательно (LT)
        case let t:
            handle(token: t, ready: ev.ready)
        }
    }
}
```

### Перезарядка oneshot-источника

```swift
try registry.register(fd: fd, token: tok, interest: [.readable, .oneshot])
// событие пришло → обработали → перед следующим ожиданием:
try registry.reregister(fd: fd, token: tok, interest: [.readable, .oneshot])
```

### Edge-triggered (только если готовы к дисциплине drain)

```swift
try registry.register(fd: fd, token: tok, interest: [.readable, .edge])
// при событии: цикл read до EAGAIN — иначе остаток данных не сигнализируется
```

---

## 13. Известные ограничения (честный список)

1. **Только Linux** (весь код под `#if os(Linux)`; на других платформах
   модуль компилируется пустым).
2. **EINTR-ретрай не вычитает истёкшее время** из таймаута (§6.3).
3. `sigmask` действует только на pwait2-пути; на fallback (ядра < 5.11)
   молча игнорируется.
4. `TimerFd` — только периодический.
5. `.exclusive`: без RDHUP (whitelist ядра), флаг ставится только при
   `register`, кейз — accept-стиль событий.
6. Debug-флаг «один Waker» не сбрасывается — повторное создание waker'а на
   том же Registry в debug-сборке трэпит, даже если первый умер.
7. `PollTimeout.nanoseconds`: ms-fallback сатурируется на ~24.8 днях
   (точное значение едет в pwait2 — там timespec 64-битный).
8. `Events` не Sendable by design; «поделиться» нельзя, нужно создавать
   свой на поток.
