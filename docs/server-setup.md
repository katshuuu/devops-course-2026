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
