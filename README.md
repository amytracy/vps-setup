# vps-setup — первичная защита свежего VPS

Набор скриптов для Ubuntu/Debian, которые стоит запустить сразу после покупки сервера.
Основная задача — убрать SSH с 22 порта, где его постоянно перебирают боты, и банить тех, кто подбирает пароли.

| Скрипт | SSH на случайный порт | fail2ban | UFW (файрвол) | Логи и отчёты | Ловушка на 22 |
|---|:-:|:-:|:-:|:-:|:-:|
| `01-basic.sh`    | ✓ | ✓ |   |   |   |
| `02-firewall.sh` | ✓ | ✓ | ✓ |   |   |
| `03-logging.sh`  | ✓ | ✓ |   | ✓ |   |
| `04-tarpit.sh`   | ✓ | ✓ |   |   | ✓ |
| `05-full.sh`     | ✓ | ✓ | ✓ | ✓ | ✓ |

Скрипты можно запускать повторно и комбинировать. Например, сначала `01-basic.sh`, потом `04-tarpit.sh`:
уже назначенный порт сохраняется, просто добавляется ловушка.

Поддерживаются Debian 11–13 и Ubuntu 20.04+, нужен systemd.

## Запуск через curl

Всё делается одной командой прямо на сервере — ничего копировать и распаковывать не нужно.
`install.sh` скачает архив репозитория во временный каталог, запустит выбранный скрипт и удалит за собой файлы.

```bash
curl -fsSL https://raw.githubusercontent.com/amytracy/vps-setup/main/install.sh | sudo bash -s -- 05-full --allow 80,443
```

Это полный вариант: SSH на случайный порт, fail2ban, UFW, ловушка endlessh на 22 и ежедневные отчёты.
Порты `80` и `443` открыты для веб-сервера — уберите `--allow 80,443`, если они не нужны.

Первый аргумент после `--` — какой скрипт запустить. Дальше идут его опции.
Если скрипт не указан, запускается `01-basic.sh`:

```bash
# 01-basic: SSH на случайный порт + fail2ban (минимум)
curl -fsSL https://raw.githubusercontent.com/amytracy/vps-setup/main/install.sh | sudo bash

# 02-firewall: то же + UFW
curl -fsSL https://raw.githubusercontent.com/amytracy/vps-setup/main/install.sh | sudo bash -s -- 02-firewall --allow 80,443

# 03-logging: то же + постоянные логи и ежедневный отчёт
curl -fsSL https://raw.githubusercontent.com/amytracy/vps-setup/main/install.sh | sudo bash -s -- 03-logging

# 04-tarpit: то же + ловушка endlessh на 22
curl -fsSL https://raw.githubusercontent.com/amytracy/vps-setup/main/install.sh | sudo bash -s -- 04-tarpit

# 05-full: всё сразу
curl -fsSL https://raw.githubusercontent.com/amytracy/vps-setup/main/install.sh | sudo bash -s -- 05-full --allow 80,443
```

Можно задать порт вручную и таймаут автоотката:

```bash
curl -fsSL https://raw.githubusercontent.com/amytracy/vps-setup/main/install.sh \
  | sudo bash -s -- 05-full --port 2222 --allow 443 --timeout 15
```

### Если не хочется запускать скачанное через пайп

```bash
curl -fsSL -o /tmp/vps-setup-install.sh \
  https://raw.githubusercontent.com/amytracy/vps-setup/main/install.sh
sudo bash /tmp/vps-setup-install.sh 05-full --allow 80,443
```

Так же можно запустить локальную копию репозитория:

```bash
git clone https://github.com/amytracy/vps-setup.git
cd vps-setup
sudo bash 05-full.sh --allow 80,443
```

### Версия и форк

По умолчанию `install.sh` берёт ветку `main`. Чтобы зафиксировать версию, укажите тег или коммит:

```bash
curl -fsSL https://raw.githubusercontent.com/amytracy/vps-setup/main/install.sh \
  | sudo VPS_SETUP_REF=v1.0.0 bash -s -- 05-full
```

Для своего форка:

```bash
curl -fsSL https://raw.githubusercontent.com/amytracy/vps-setup/main/install.sh \
  | sudo VPS_SETUP_REPO=username/vps-setup bash -s -- 05-full
```

> `curl … | sudo bash` запускает код из интернета. Если хотите сначала посмотреть, что выполняется,
> скачайте `install.sh` и скрипты в репозитории или зафиксируйте `VPS_SETUP_REF` на конкретном коммите.

## Подтверждение входа

В конце скрипт **попросит открыть новый терминал** и проверить вход по новому порту:

```
ssh -p 23817 root@IP_СЕРВЕРА
```

Если вход работает, ответьте `yes`. Если ответить `no` или ничего не ответить за 10 минут,
то таймер автоматически вернёт SSH на 22 и выключит UFW. Так в сервер нельзя не попасть
из-за ошибки (например, если у хостера есть свой файрвол, где новый порт не открыт).

> ⚠️ Если в панели хостера есть **Firewall / Security Group** (Hetzner Cloud Firewall, AWS, Oracle, Yandex Cloud…),
> откройте там новый порт **до** подтверждения.

При запуске через `curl | sudo bash` подтверждение читается напрямую из `/dev/tty`, поэтому пайп ему не мешает.
Если терминала нет (cloud-init, Ansible, CI), скрипт завершится с ошибкой — добавьте `--no-confirm`:

```bash
curl -fsSL https://raw.githubusercontent.com/amytracy/vps-setup/main/install.sh \
  | sudo bash -s -- 05-full --allow 80,443 --no-confirm
```

В режиме `--no-confirm` таймера автоотката нет: порт в файрволе хостера нужно открыть заранее.

## Опции (у всех скриптов одинаковые)

```
--port N         задать порт SSH вручную (1024-65535); по умолчанию случайный из 10000-32000
--allow LIST     (02, 05) открыть в UFW дополнительные порты: 80,443,51820/udp,6000:6010/tcp
--timeout MIN    через сколько минут откатывать, если вход не подтверждён (по умолчанию 10)
--no-confirm     без подтверждения и без таймера автоотката (для cloud-init/Ansible)
-h, --help       справка
```

## Что делает каждый модуль

### SSH на случайный порт
- Создаёт `/etc/ssh/sshd_config.d/10-vps-port.conf` с `Port N`. Другие строки `Port` в конфигах комментирует меткой `#vps-setup# `, чтобы их можно было вернуть.
- Перед перезапуском проверяет конфиг командой `sshd -t`. После перезапуска убеждается, что порт действительно слушается. Если что-то пошло не так, сам всё откатывает.
- Поддерживает socket activation в Ubuntu 22.10+/24.04: там порт слушает `ssh.socket`, а не `sshd`.
- Порт берётся из диапазона 10000–32000, ниже эфемерных портов Linux. Он сохраняется в `/etc/vps-setup.conf`.
- Текущая SSH-сессия при перезапуске не обрывается.

### fail2ban
Настройки лежат в `/etc/fail2ban/jail.d/zz-vps-setup.local`:
- **sshd**: 3 неудачные попытки за 10 минут дают бан на 1 час. Для повторных нарушителей срок растёт (×2 каждый раз, максимум 4 недели). Логи читаются через systemd-journal, потому что в Debian 12 нет `auth.log`.
- **recidive**: если IP забанили 5 раз за сутки, он получает бан на неделю **на все порты**.
- Ваш текущий IP попадает в `ignoreip`, чтобы вы случайно не забанили себя.
- Если UFW включён, баны делаются через UFW. Иначе используется nftables или iptables.
- История банов хранится 30 дней.

### UFW (02, 05)
- Входящие соединения запрещены по умолчанию, исходящие разрешены.
- SSH открыт с `limit`: не больше 6 новых подключений за 30 секунд с одного IP.
- 22/tcp закрыт. Если стоит ловушка, он открыт для неё.
- Порты из `--allow` открываются.
- `ufw logging low`: заблокированные пакеты попадают в лог.

> ⚠️ **Docker**: порты, опубликованные через `docker run -p`, **обходят UFW**, потому что Docker сам пишет правила в iptables.
> Публикуйте порты как `-p 127.0.0.1:8080:80` и ставьте перед контейнерами reverse-proxy, либо используйте [ufw-docker](https://github.com/chaifeng/ufw-docker).

### Логи (03, 05)
- Журнал systemd хранится на диске (переживает перезагрузку). Лимит — 500 МБ или 3 месяца.
- sshd пишет `LogLevel VERBOSE`: в логе видно, каким ключом заходили.
- Таймер `vps-report.timer` каждую ночь создаёт:
  - `/var/log/vps-report/ГГГГ-ММ-ДД.txt` — отчёт за сутки (хранится 365 дней): неудачные входы, топ IP и логинов, успешные входы, баны, статистика ловушки, на какие порты стучались, команды sudo;
  - `/var/log/vps-archive/ГГГГ-ММ-ДД/*.log.gz` — сырые логи ssh, sudo, fail2ban, endlessh и ufw в текстовом виде (хранятся 180 дней).
- Отчёт можно получить вручную: `sudo vps-report` (за вчера) или `sudo vps-report 2026-11-03`.

### Ловушка endlessh на 22 (04, 05)
[endlessh](https://github.com/skeeto/endlessh) — SSH tarpit. Бот подключается к 22 порту и видит, что сервер начал
отвечать как SSH. Дальше сервер раз в 10 секунд присылает ещё одну случайную строку «приветствия», и так бесконечно.
Бот ждёт настоящего баннера `SSH-2.0-…` и висит в ловушке минуты, иногда часы. Сканеры видят открытый 22 порт и продолжают туда стучаться,
а настоящий SSH остаётся на другом порту.

- Один процесс держит тысячи подключений и почти не тратит CPU и RAM.
- Запускается с одним правом `CAP_NET_BIND_SERVICE` под динамическим непривилегированным пользователем.
- **fail2ban на 22 не вешается специально**: бан разорвал бы соединение и освободил бота.
- Посмотреть, кто сейчас в ловушке: `sudo vps-status`. Смотреть в реальном времени: `journalctl -u endlessh -f`.
- Ubuntu: пакет находится в репозитории `universe`. На обычных образах он включён, иначе выполните `sudo add-apt-repository universe`.

## Утилиты (ставятся в /usr/local/sbin)

| Команда | Что делает |
|---|---|
| `sudo vps-status` | Порт SSH, баны fail2ban, правила UFW, сколько ботов сейчас в ловушке и кто дольше всех просидел |
| `sudo vps-rollback` | Вернуть SSH на 22: выключить endlessh, открыть 22 в UFW, переключить fail2ban |
| `sudo vps-rollback --disable-ufw` | То же самое и выключить UFW |
| `sudo vps-report [ДАТА]` | Отчёт за день (если стоит модуль логов) |

Копии всех изменённых файлов лежат в `/root/vps-setup-backup/<дата-время>/`.

## После установки

```bash
sudo vps-status                 # порт SSH, баны, UFW, ловушка
ufw status verbose              # правила файрвола (если ставили 02/05)
fail2ban-client status sshd     # статистика банов
journalctl -u endlessh -f       # боты в ловушке в реальном времени (04/05)
sudo vps-report                 # отчёт за вчера (03/05)
```

Новый порт также записан в `/etc/vps-setup.conf` (файл доступен только root).
Удобно добавить сервер в `~/.ssh/config`:

```
Host myvps
    HostName IP_СЕРВЕРА
    Port 23817
    User root
```

## Чего скрипты НЕ делают (стоит сделать самому)

- **Вход только по ключу.** Скрипты не трогают аутентификацию, чтобы вы не потеряли доступ. Когда вход по ключу заработает, создайте файл:
  ```bash
  cat >/etc/ssh/sshd_config.d/20-auth.conf <<'EOF'
  PasswordAuthentication no
  KbdInteractiveAuthentication no
  PermitRootLogin prohibit-password
  EOF
  sshd -t && systemctl reload ssh
  ```
- Отдельный пользователь с sudo вместо root.
- Автоматические обновления безопасности: `apt install unattended-upgrades`.

## Структура

```
install.sh                 загрузчик для запуска через curl (скачивает архив и запускает скрипт)
01-basic.sh … 05-full.sh   точки входа (задают набор модулей и вызывают run_setup)
lib/common.sh              вся логика: ssh, fail2ban, ufw, endlessh, логи, автооткат
tools/rollback.sh          → /usr/local/sbin/vps-rollback (самодостаточный, его вызывает таймер)
tools/status.sh            → /usr/local/sbin/vps-status
tools/report.sh            → /usr/local/sbin/vps-report
```

`install.sh` принимает первым аргументом `01`–`05`, `01-basic`…`05-full` или имя файла (`05-full.sh`).
Если запустить его из клонированного репозитория, он не скачивает архив, а использует локальные файлы.
