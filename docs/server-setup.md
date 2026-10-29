# Конфигурация виртуальной машины devops-vm

Документ описывает состояние учебного сервера после ПР5 и позволяет восстановить его
со снимка `01-clean-install`. Все команды выполняются в том порядке, в котором приведены.
Хостовая система: MacBook (Apple M3, macOS), VirtualBox 7.1, образ Ubuntu Server 24.04 LTS (arm64).

## 1. Параметры машины

| Параметр | Значение |
|---|---|
| Имя ВМ / hostname | `devops-vm` (FQDN `devops-vm.devops.local`) |
| ОС | Ubuntu Server 24.04 LTS, arm64, без GUI, без featured snaps |
| Оперативная память | 2048 МБ |
| Процессор | 2 ядра |
| Диск | 25 ГБ, динамически расширяемый |

## 2. Сетевые интерфейсы

| Адаптер VirtualBox | Интерфейс в ВМ | Адрес | Назначение |
|---|---|---|---|
| Адаптер 1 — NAT | `enp0s8` | `10.0.2.15/24` (DHCP), шлюз `10.0.2.2` | доступ в Интернет (apt), SSH с хоста через проброс порта |
| Адаптер 2 — Host-only (`vboxnet0`, `192.168.56.0/24`) | `enp0s9` | `192.168.56.101/24` (DHCP VirtualBox) | прямой доступ с хоста: `devops.local`, веб-сервер в ПР6 |

Проверка: `ip -brief address`.

## 3. Правило проброса портов

Адаптер 1 (NAT) → «Проброс портов»:

| Имя | Протокол | Адрес хоста | Порт хоста | Адрес гостя | Порт гостя |
|---|---|---|---|---|---|
| ssh | TCP | 127.0.0.1 | 2222 | (пусто) | **2222** |

> На чистом снимке `01-clean-install` порт гостя был `22`. Его меняют на `2222`
> **только после** перевода sshd на порт 2222 (шаг 5.4 ниже), иначе соединение
> оборвётся с `Connection reset by peer`.

## 4. Учётные записи

| Пользователь | UID | Группы | Аутентификация по SSH |
|---|---|---|---|
| `student` | 1000 | student, adm, cdrom, sudo, dip, plugdev, users, lxd | **запрещена** (не входит в `AllowUsers`); вход только с консоли VirtualBox |
| `devops` | 1001 | devops, sudo, users | только по ключу ED25519 `devops-vm-key` |
| `root` | 0 | — | запрещена (`PermitRootLogin no`) |

Создание пользователя и ключа:

```bash
# на ВМ (под student)
sudo adduser devops
sudo usermod -aG sudo devops

# на хосте (macOS)
ssh-keygen -t ed25519 -C "devops-vm-key" -f ~/.ssh/devops_vm
ssh-copy-id -i ~/.ssh/devops_vm.pub -p 2222 devops@127.0.0.1

# на ВМ (под devops) — права, которых требует sshd
chmod 700 ~/.ssh && chmod 600 ~/.ssh/authorized_keys
```

Клиентский `~/.ssh/config` на хосте:

```
Host devops
    HostName 127.0.0.1
    Port 2222
    User devops
    IdentityFile ~/.ssh/devops_vm
    IdentitiesOnly yes

Host devops.local
    Port 2222
    User devops
    IdentityFile ~/.ssh/devops_vm
    IdentitiesOnly yes
```

Отпечаток ключа хоста сверяется командой `sudo ssh-keygen -lf /etc/ssh/ssh_host_ed25519_key.pub`.

## 5. Служба SSH

Основной файл `/etc/ssh/sshd_config` не изменяется (копия: `/etc/ssh/sshd_config.backup`).
Изменения — в файле `/etc/ssh/sshd_config.d/99-hardening.conf`:

```
Port 2222
PermitRootLogin no
PasswordAuthentication no
PubkeyAuthentication yes
PermitEmptyPasswords no
MaxAuthTries 3
LoginGraceTime 30
AllowUsers devops
X11Forwarding no
ClientAliveInterval 300
ClientAliveCountMax 2
```

Последовательность применения (текущую SSH-сессию **не закрывать**, проверять во втором терминале):

```bash
# 5.1 конфликтующая директива установщика (файлы читаются по алфавиту, действует первое значение)
grep -r "PasswordAuthentication" /etc/ssh/sshd_config.d/ /etc/ssh/sshd_config
sudo sed -i 's/^PasswordAuthentication yes/#PasswordAuthentication yes/' \
  /etc/ssh/sshd_config.d/50-cloud-init.conf

# 5.2 синтаксис и действующие значения
sudo sshd -t && echo "Конфигурация корректна"
sudo sshd -T | grep -Ei "^(port|permitrootlogin|passwordauthentication|maxauthtries|allowusers)"

# 5.3 отказ от socket activation (иначе порт остаётся 22)
sudo systemctl disable --now ssh.socket
sudo systemctl enable --now ssh.service
sudo systemctl restart ssh
sudo ss -tlnp | grep sshd        # 0.0.0.0:2222 и [::]:2222

# 5.4 в VirtualBox: проброс порта, «Порт гостя» 22 -> 2222
# 5.5 проверка с хоста: ssh devops — успех; root и вход без ключа — Permission denied (publickey)
```

## 6. Правила межсетевого экрана

Политики: `deny (incoming)`, `allow (outgoing)`, `disabled (routed)`; журнал `on (medium)`.

| № | Порт | Действие | Комментарий |
|---|---|---|---|
| 1 | 80/tcp | ALLOW IN | HTTP (ПР6) |
| 2 | 443/tcp | ALLOW IN | HTTPS (ПР6) |
| 3 | 2222/tcp | LIMIT IN | SSH rate-limited (≥ 6 соединений за 30 с — блокировка источника) |

Правила дублируются для IPv6. Порядок команд важен — разрешающее правило для SSH до `enable`:

```bash
sudo ufw default deny incoming
sudo ufw default allow outgoing
sudo ufw limit 2222/tcp comment 'SSH rate-limited'   # не "ufw allow ssh": это порт 22 из /etc/services
sudo ufw allow 80/tcp comment 'HTTP'
sudo ufw allow 443/tcp comment 'HTTPS'
sudo ufw enable
sudo ufw logging medium
sudo ufw status verbose
```

### Имена

```bash
# на ВМ
sudo hostnamectl set-hostname devops-vm
sudo sed -i 's/^127.0.1.1.*/127.0.1.1 devops-vm.devops.local devops-vm/' /etc/hosts
hostname -f                      # devops-vm.devops.local

# на хосте (macOS)
echo '192.168.56.101 devops.local' | sudo tee -a /etc/hosts
ssh devops.local
```

## 7. Снимки состояния

| Снимок | Момент создания | Состояние |
|---|---|---|
| `01-clean-install` | 26.10.2026, после установки ОС, `apt upgrade` и выключения ВМ | чистая система, SSH на 22, вход по паролю |
| `02-keys-configured` | 27.10.2026, после задания 1 | пользователь `devops`, ключ в `authorized_keys`, `~/.ssh/config` на хосте |
| `03-ssh-hardened` | 27.10.2026, после задания 2 | sshd на 2222, только ключи, root запрещён |

Итоговая проверка конфигурации: `bash scripts/audit.sh` (код возврата 0).

## 8. Веб-сервер

Выполняется после раздела 6 (порты 80/tcp и 443/tcp уже разрешены в UFW; профили
`Nginx HTTP/HTTPS/Full` **не** добавлять — правила продублируются).

| Параметр | Значение |
|---|---|
| Пакет | `nginx` из репозитория Ubuntu (nginx/1.24.0), служба `nginx.service`, включена в автозапуск |
| Процессы | главный — `root` (читает конфигурацию и ключ, открывает порты 80/443), рабочие — `www-data` |
| Конфигурация ресурса | `/etc/nginx/sites-available/devops-site`, ссылка `/etc/nginx/sites-enabled/devops-site` |
| Стандартный ресурс | отключён: ссылка `/etc/nginx/sites-enabled/default` удалена, файл в `sites-available/` сохранён |
| Каталог ресурса | `/var/www/devops-site`, владелец `devops:devops`, права `755` (каталоги) / `644` (файлы) |
| Журналы | `/var/log/nginx/devops-site.access.log`, `/var/log/nginx/devops-site.error.log` (в обоих блоках `server`) |
| Сертификат | `/etc/ssl/certs/devops.crt`, `root:root`, права `644`, самоподписанный, CN и SAN `DNS:devops.local`, RSA 2048, SHA-256 |
| Закрытый ключ | `/etc/ssl/private/devops.key`, `root:root`, права `600`; из `/etc/ssl/private` не копируется, в репозиторий не добавляется |
| Срок действия сертификата | 365 дней с момента формирования (сформирован 27.10.2026, действует до 27.10.2027); контроль — `scripts/audit.sh`, проверка за 30 дней |
| Доставка содержимого | `scripts/deploy.sh` из репозитория (rsync `--delete --chmod=D755,F644`) |

### 8.1 Установка и каталог ресурса

```bash
sudo apt update && sudo apt install -y nginx rsync
sudo mkdir -p /var/www/devops-site
sudo chown -R devops:devops /var/www/devops-site
```

### 8.2 Сертификат

```bash
sudo openssl req -x509 -nodes -days 365 -newkey rsa:2048 \
  -keyout /etc/ssl/private/devops.key \
  -out /etc/ssl/certs/devops.crt \
  -subj "/CN=devops.local" \
  -addext "subjectAltName=DNS:devops.local"
sudo ls -l /etc/ssl/private/devops.key /etc/ssl/certs/devops.crt   # 600 root / 644 root
```

После повторного формирования сертификат заново копируется на хост
(`scp devops:/etc/ssl/certs/devops.crt ~/devops.crt`) — старый перестанет проходить проверку.

### 8.3 Конфигурация `/etc/nginx/sites-available/devops-site`

```nginx
# Блок 1: перенаправление HTTP -> HTTPS
server {
    listen 80;
    listen [::]:80;
    server_name devops.local;

    return 301 https://$host$request_uri;

    access_log /var/log/nginx/devops-site.access.log;
    error_log  /var/log/nginx/devops-site.error.log;
}

# Блок 2: ресурс по HTTPS
server {
    listen 443 ssl;
    listen [::]:443 ssl;
    server_name devops.local;

    ssl_certificate     /etc/ssl/certs/devops.crt;
    ssl_certificate_key /etc/ssl/private/devops.key;
    ssl_protocols       TLSv1.2 TLSv1.3;

    root /var/www/devops-site;
    index index.html;

    location / {
        try_files $uri $uri/ =404;
    }

    error_page 404 /404.html;

    access_log /var/log/nginx/devops-site.access.log;
    error_log  /var/log/nginx/devops-site.error.log;
}
```

Заголовок `Strict-Transport-Security` **не** добавляется (самоподписанный сертификат).
Если на машине отключён IPv6, строки `listen [::]:...` удаляются.

```bash
sudo ln -s /etc/nginx/sites-available/devops-site /etc/nginx/sites-enabled/
sudo rm /etc/nginx/sites-enabled/default
sudo nginx -t && sudo systemctl reload nginx    # только reload, не restart
sudo ss -tlnp | grep nginx                      # 80 и 443
```

### 8.4 Проверка с хоста

```bash
curl -I http://devops.local                          # 301, Location: https://devops.local/
scp devops:/etc/ssl/certs/devops.crt ~/devops.crt
curl --cacert ~/devops.crt -I https://devops.local   # 200 OK без -k
scripts/deploy.sh                                    # доставка содержимого site/
bash scripts/audit.sh                                # на сервере, код возврата 0
```

### 8.5 Снимок состояния

| Снимок | Момент создания | Состояние |
|---|---|---|
| `04-nginx-https` | 27.10.2026, после задания 2 ПР6 | nginx, ресурс devops.local по HTTPS, перенаправление HTTP → HTTPS |

## 9. Контейнеризация

Выполняется после раздела 8 (Nginx с HTTPS уже настроен).

| Параметр | Значение |
|---|---|
| Docker Engine | 29.9.2 (`docker-ce`, `docker-ce-cli`, `containerd.io`, `docker-buildx-plugin`, `docker-compose-plugin`) из официального репозитория `download.docker.com`; пакет `docker.io` не используется |
| Docker Compose | плагин v5.6.1 (`docker compose`) |
| Участники группы `docker` | только `devops` (имеет `sudo`); группа даёт права, эквивалентные root |
| Проект | `/home/devops/app` (имя проекта Compose — `app`), доставляется из `app/` репозитория: `rsync -avz --delete --exclude=.env app/ devops:app/` |
| Файл `.env` | `/home/devops/app/.env`, владелец `devops`, права `600`; создаётся только на сервере из `.env.example`, в репозиторий и на хост не копируется |
| Сервисы | `db` — `postgres:16-alpine` (healthcheck `pg_isready`); `app` — образ `devops-app:1.0` (сборка из `app/Dockerfile`, процесс от пользователя `app`) |
| Публикуемые порты | `app`: `127.0.0.1:5000 -> 5000/tcp` (только для Nginx); `db`: порт 5432 **не публикуется** |
| Сеть | пользовательская сеть `app_backend` (bridge); приложение обращается к СУБД по имени `db` |
| Именованный том | `app_db_data` → `/var/lib/postgresql/data`; переживает `docker compose down`, удаляется только `down -v` |
| Политика перезапуска | `restart: unless-stopped` у обоих сервисов |
| Обратный прокси | `location /app/` в HTTPS-блоке `/etc/nginx/sites-available/devops-site` → `http://127.0.0.1:5000/` |

### 9.1 Установка Docker Engine

```bash
# официальная инструкция: https://docs.docker.com/engine/install/ubuntu/
for p in docker.io docker-doc docker-compose podman-docker containerd runc; do sudo apt-get remove -y $p; done
sudo apt-get update && sudo apt-get install -y ca-certificates curl
sudo install -m 0755 -d /etc/apt/keyrings
sudo curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
sudo chmod a+r /etc/apt/keyrings/docker.asc
echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] \
https://download.docker.com/linux/ubuntu $(. /etc/os-release && echo "$VERSION_CODENAME") stable" \
  | sudo tee /etc/apt/sources.list.d/docker.list > /dev/null
sudo apt-get update
sudo apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
sudo usermod -aG docker devops        # затем новая SSH-сессия
docker version && docker compose version && docker run --rm hello-world
```

### 9.2 Развёртывание проекта

```bash
# [Хост] из корня репозитория
rsync -avz --delete --exclude=.env app/ devops:app/

# [VM] первый запуск: секрет создаётся на сервере
cd ~/app
cp .env.example .env
chmod 600 .env
sed -i "s/^POSTGRES_PASSWORD=.*/POSTGRES_PASSWORD=$(openssl rand -hex 16)/" .env
docker compose up -d --build
docker compose ps                     # db: (healthy), app: Up
curl -s http://127.0.0.1:5000/        # Hello from Docker, ... Visits: N
sudo ss -tlnp | grep -E ':(5000|5432)\b'   # только 127.0.0.1:5000
```

Параметр `--exclude=.env` в rsync обязателен: без него `--delete` удалит `.env` на сервере.
Публикация порта без адреса (`"5000:5000"`) **запрещена**: Docker добавляет правила DNAT
в свои цепочки iptables, и порт становится доступен из сети в обход UFW.
`docker compose down -v` удаляет том с базой данных — не выполнять на рабочем сервере.

### 9.3 Обратный прокси

В блок `server` для порта 443 (раздел 8.3) перед `error_page` добавлено:

```nginx
    location /app/ {
        proxy_pass http://127.0.0.1:5000/;
        proxy_set_header Host              $host;
        proxy_set_header X-Real-IP         $remote_addr;
        proxy_set_header X-Forwarded-For   $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
    }
```

```bash
sudo nginx -t && sudo systemctl reload nginx
curl --cacert ~/devops.crt https://devops.local/app/health   # [Хост] ok
```

Код `502 Bad Gateway` и запись `connect() failed (111: Connection refused) while connecting to upstream`
в `/var/log/nginx/devops-site.error.log` означают, что контейнер `app` не запущен
(`docker compose ps`, `docker compose logs app`).

### 9.4 Снимок состояния

| Снимок | Момент создания | Состояние |
|---|---|---|
| `05-docker-compose` | 27.10.2026, после задания 2 ПР7 | Docker Engine, проект `app` (app + db), том `app_db_data` |
