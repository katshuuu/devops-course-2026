# Восстановление стенда ПР5 → ПР8 (КР2, вариант 3)

Хост: MacBook M3. ВМ: `devops-vm`, Ubuntu Server 24.04 arm64.  
Вариант КР2: `stats.devops.local`, порт `8003`, `STUDENT=Shustalova`.

Выполняйте команды **по одной**. На Mac — в Terminal; на ВМ — после `ssh`.

---

## 0. Подготовка на Mac

```bash
cd ~
git clone https://github.com/katshuuu/devops-course-2026.git
cd devops-course-2026
git pull
```

Создайте на GitHub пустой репозиторий **`katshuuu/devops-kr2`** (без README), затем:

```bash
mkdir -p ~/devops-kr2 && cd ~/devops-kr2
# файлы приложения возьмите из инструкции ассистента / скопируйте готовый каркас
```

Ключ и SSH-config (если ещё нет):

```bash
ls ~/.ssh/devops_vm || ssh-keygen -t ed25519 -C "devops-vm-key" -f ~/.ssh/devops_vm -N ""
```

---

## 1. ПР5 — пользователь, ключ, hardening, UFW

Пока проброс: host `2222` → guest `22`.

```bash
ssh -p 2222 student@127.0.0.1
```

На ВМ:

```bash
sudo apt-get update && sudo apt-get upgrade -y
sudo adduser devops
sudo usermod -aG sudo devops
exit
```

На Mac:

```bash
ssh-copy-id -i ~/.ssh/devops_vm.pub -p 2222 devops@127.0.0.1
```

Добавьте в `~/.ssh/config`:

```
Host devops
    HostName 127.0.0.1
    Port 2222
    User devops
    IdentityFile ~/.ssh/devops_vm
    IdentitiesOnly yes
```

```bash
ssh -o BatchMode=yes devops 'echo OK'
```

Снимок (ВМ выключить):

```bash
ssh devops 'sudo poweroff'
VBoxManage snapshot devops-vm take "01-clean-install"
VBoxManage snapshot devops-vm take "02-keys-configured"
VBoxManage startvm devops-vm --type gui
```

Hardening — сессию `ssh devops` не закрывать; второй терминал для проверки.

На ВМ:

```bash
sudo cp -p /etc/ssh/sshd_config /etc/ssh/sshd_config.backup
sudo sed -i 's/^PasswordAuthentication yes/# PasswordAuthentication yes/' /etc/ssh/sshd_config.d/50-cloud-init.conf
sudo tee /etc/ssh/sshd_config.d/99-hardening.conf >/dev/null <<'EOF'
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
EOF
sudo sshd -t
sudo systemctl disable --now ssh.socket
sudo systemctl enable --now ssh.service
sudo systemctl restart ssh
sudo ss -tlnp | grep sshd
```

На Mac:

```bash
VBoxManage controlvm devops-vm natpf1 delete ssh
VBoxManage controlvm devops-vm natpf1 "ssh,tcp,127.0.0.1,2222,,2222"
ssh -o BatchMode=yes devops 'echo NEW_OK'
```

UFW + hostname:

```bash
ssh devops
sudo ufw default deny incoming
sudo ufw default allow outgoing
sudo ufw limit 2222/tcp
sudo ufw allow 80/tcp
sudo ufw allow 443/tcp
sudo ufw --force enable
sudo ufw logging medium
sudo hostnamectl set-hostname devops-vm
sudo sed -i 's/^127\.0\.1\.1.*/127.0.1.1 devops-vm.devops.local devops-vm/' /etc/hosts
hostname -f
scp ~/devops-course-2026/scripts/audit.sh devops:~/audit.sh
sudo bash ~/audit.sh --stage ssh
```

Снимок `03-ssh-hardened`.

---

## 2. Host-only + devops.local (нужно для ПР6–8)

Если `vboxnet0` заработал:

```bash
VBoxManage controlvm devops-vm poweroff
VBoxManage modifyvm devops-vm --nic2 hostonly --hostonlyadapter2 vboxnet0
VBoxManage startvm devops-vm --type gui
```

На Mac:

```bash
grep -q 'devops.local' /etc/hosts || echo '192.168.56.101 devops.local' | sudo tee -a /etc/hosts
grep -q 'stats.devops.local' /etc/hosts || echo '192.168.56.101 stats.devops.local' | sudo tee -a /etc/hosts
```

На ВМ проверьте: `ip -brief address` — у host-only должен быть `192.168.56.101`.

---

## 3. ПР6 — Nginx + HTTPS + site/

На ВМ:

```bash
sudo apt-get install -y nginx rsync
sudo mkdir -p /var/www/devops-site
sudo chown devops:devops /var/www/devops-site
sudo openssl req -x509 -nodes -days 365 -newkey rsa:2048 \
  -keyout /etc/ssl/private/devops.key \
  -out /etc/ssl/certs/devops.crt \
  -subj "/CN=devops.local" \
  -addext "subjectAltName=DNS:devops.local"
sudo chmod 600 /etc/ssl/private/devops.key
sudo chmod 644 /etc/ssl/certs/devops.crt
```

Конфиг `/etc/nginx/sites-available/devops-site` — как в `docs/server-setup.md` (HTTP→HTTPS, root `/var/www/devops-site`).

```bash
sudo ln -sf /etc/nginx/sites-available/devops-site /etc/nginx/sites-enabled/
sudo rm -f /etc/nginx/sites-enabled/default
sudo nginx -t && sudo systemctl reload nginx
```

На Mac:

```bash
scp -P 2222 devops@127.0.0.1:/etc/ssl/certs/devops.crt ~/devops.crt
cd ~/devops-course-2026
./scripts/deploy.sh
curl --cacert ~/devops.crt -I https://devops.local
```

Снимок `04-nginx-https`. Аудит: `sudo bash ~/audit.sh --stage web`.

---

## 4. ПР7 — Docker app + postgres

Установка Docker CE (noble/arm64) по документации Docker, пользователь `devops` в группе `docker`.

```bash
rsync -avz --delete --exclude=.env ~/devops-course-2026/app/ devops:app/
ssh devops
cd ~/app
umask 077
cp .env.example .env
chmod 600 .env
# задайте POSTGRES_PASSWORD через openssl rand -hex 16
docker compose up -d --build
```

Добавьте в Nginx `location /app/` → `http://127.0.0.1:5000/`.

Снимок `05-docker-compose`. Аудит: `sudo bash ~/audit.sh --stage docker`.

---

## 5. ПР8 / КР2 — stats.devops.local:8003

Снимок `06-before-kr2`. Сохраните UFW: `sudo ufw status numbered > ~/ufw-before-kr2.txt`.

Репозиторий `devops-kr2`, ветка `kr2/variant-3`, исправленные Dockerfile / compose / .gitignore (см. отчёт).

На сервере:

```bash
rsync -avz --delete --exclude=.env ~/devops-kr2/ devops:kr2/
ssh devops
cd ~/kr2
umask 077
cp .env.example .env
chmod 600 .env
sed -i "s/^REDIS_PASSWORD=.*/REDIS_PASSWORD=$(openssl rand -hex 32)/" .env
docker compose up -d --build
```

Сертификат и Nginx `sites-available/kr2` для `stats.devops.local` → `127.0.0.1:8003` (текст в отчёте ПР8).

```bash
scp devops:/etc/ssl/certs/kr2.crt ~/kr2.crt
curl --cacert ~/kr2.crt https://stats.devops.local/
curl --cacert ~/kr2.crt https://stats.devops.local/whoami
sudo bash ~/audit.sh --stage kr2
```

Ожидается: **19 OK**, код **0**. Снимок `07-kr2`. PR из `kr2/variant-3` в `main` без merge.

---

## Скриншоты из отчёта — что снимать

| Рисунок | Что показать |
|---|---|
| Nginx devops-site | `cat` конфига, `nginx -t`, `curl http://devops.local` |
| HTTPS devops.local | предупреждение сертификата, страница «DevOps Course 2026» |
| Снимки VB | дерево 01…07 |
| rsync site/ | dry-run и фактическая доставка |
| stats.devops.local | ERR_CERT, ответ `KR2 \| Shustalova \| … hits:`, /whoami |
| Аудит | 19 OK, diff UFW пуст, права 600 |
