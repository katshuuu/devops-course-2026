#!/usr/bin/env bash
set -euo pipefail
cd ~/devops-kr2
git fetch origin && git checkout kr2/variant-3 && git pull origin kr2/variant-3

# --- app root ---
cat > 'app.py' << 'EOF'
# KR2: Shustalova
import os
import socket

import redis
from flask import Flask, request

app = Flask(__name__)

r = redis.Redis(
    host=os.getenv("REDIS_HOST", "localhost"),
    port=6379,
    password=os.getenv("REDIS_PASSWORD"),
    socket_connect_timeout=2,
    decode_responses=True,
)


@app.route("/health")
def health():
    return "ok\n"


@app.route("/")
def index():
    hits = r.incr("hits")
    student = os.getenv("STUDENT", "unknown")
    return f"KR2 | {student} | container {socket.gethostname()} | hits: {hits}\n"


@app.route("/whoami")
def whoami():
    return (
        f"scheme: {request.headers.get('X-Forwarded-Proto', 'none')}\n"
        f"client: {request.headers.get('X-Real-IP', 'none')}\n"
        f"host: {request.headers.get('Host', 'none')}\n"
    )
EOF

cat > 'Dockerfile' << 'EOF'
FROM python:3.12-slim

RUN useradd --system --no-create-home app

WORKDIR /app

COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

COPY app.py .

USER app

EXPOSE 8003
CMD ["gunicorn", "--bind", "0.0.0.0:8003", "--access-logfile", "-", "app:app"]
EOF

cat > 'docker-compose.yml' << 'EOF'
services:
  app:
    build: .
    image: kr2-app:1.0
    env_file: .env
    environment:
      REDIS_HOST: redis
      STUDENT: Shustalova
    ports:
      - "127.0.0.1:8003:8003"
    depends_on:
      redis:
        condition: service_healthy
    networks:
      - backend
    restart: unless-stopped

  redis:
    image: redis:7-alpine
    command: ["redis-server", "--appendonly", "yes", "--requirepass", "${REDIS_PASSWORD:?REDIS_PASSWORD is not set}"]
    env_file: .env
    volumes:
      - redis_data:/data
    networks:
      - backend
    healthcheck:
      test: ["CMD-SHELL", "redis-cli -a \"$$REDIS_PASSWORD\" --no-auth-warning ping | grep -q PONG"]
      interval: 5s
      timeout: 3s
      retries: 5
    restart: unless-stopped

volumes:
  redis_data:

networks:
  backend:
EOF

cat > 'README.md' << 'EOF'
# KR2 template

Counter service on Flask + Redis.

Local run: `pip install -r requirements.txt && flask --app app run`
EOF

cat > 'requirements.txt' << 'EOF'
flask==3.0.3
redis==5.0.8
gunicorn==22.0.0
EOF

mkdir -p nginx scripts
cat > nginx/kr2 << 'EOF'
# stats.devops.local — приложение КР2 (вариант 3), upstream 127.0.0.1:8003

# Блок 1: перенаправление HTTP -> HTTPS
server {
    listen 80;
    listen [::]:80;
    server_name stats.devops.local;

    return 301 https://$host$request_uri;

    access_log /var/log/nginx/kr2.access.log;
    error_log  /var/log/nginx/kr2.error.log;
}

# Блок 2: обратный прокси по HTTPS
server {
    listen 443 ssl;
    listen [::]:443 ssl;
    server_name stats.devops.local;

    ssl_certificate     /etc/ssl/certs/kr2.crt;
    ssl_certificate_key /etc/ssl/private/kr2.key;
    ssl_protocols       TLSv1.2 TLSv1.3;

    location / {
        proxy_pass http://127.0.0.1:8003;
        proxy_set_header Host              $host;
        proxy_set_header X-Real-IP         $remote_addr;
        proxy_set_header X-Forwarded-For   $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
    }

    access_log /var/log/nginx/kr2.access.log;
    error_log  /var/log/nginx/kr2.error.log;
}
EOF

cat > scripts/audit.sh << 'EOF'
#!/usr/bin/env bash
# Аудит базовой защиты сервера devops-vm (ПР5, «Инструменты девопс»).
# Код возврата: 0 — все проверки пройдены, 1 — есть хотя бы одна непройденная.
set -uo pipefail
PASS=0; FAIL=0

check() {
  local desc="$1" expected="$2" actual="$3"
  if [[ "$actual" == "$expected" ]]; then
    echo "  [OK] $desc"; ((PASS++))
  else
    echo "  [FAIL] $desc (ожидалось: '$expected', получено: '$actual')"; ((FAIL++))
  fi
}

echo "Аудит конфигурации: $(hostname -f), $(date '+%Y-%m-%d %H:%M')"

echo "[1] Служба SSH"
check "Вход от имени root запрещён" "no" "$(sudo sshd -T | awk '/^permitrootlogin/{print $2}')"
check "Парольная аутентификация отключена" "no" "$(sudo sshd -T | awk '/^passwordauthentication/{print $2}')"

# TODO 1: значение параметра port отлично от 22.
# sshd -T может вывести несколько строк port, если задано несколько портов;
# проверяем, что ни одна из них не равна 22.
SSH_PORTS="$(sudo sshd -T | awk '/^port /{print $2}' | paste -sd, -)"
if [[ -n "$SSH_PORTS" && ",$SSH_PORTS," != *",22,"* ]]; then
  check "Порт SSH отличен от 22 (текущий: $SSH_PORTS)" "yes" "yes"
else
  check "Порт SSH отличен от 22 (текущий: ${SSH_PORTS:-не определён})" "yes" "no"
fi

# TODO 2: значение параметра maxauthtries равно 3
check "Максимальное число попыток аутентификации равно 3" "3" \
  "$(sudo sshd -T | awk '/^maxauthtries /{print $2}')"

echo "[2] Межсетевой экран"
check "Межсетевой экран активен" "active" "$(sudo ufw status | awk '/^Status:/{print $2}')"

# TODO 3: политика по умолчанию для входящего трафика равна deny
# Строка вида: "Default: deny (incoming), allow (outgoing), disabled (routed)"
check "Политика по умолчанию для входящего трафика — deny" "deny" \
  "$(sudo ufw status verbose | grep '^Default:' | sed -n 's/^Default: \([a-z]*\) (incoming).*/\1/p')"

echo "[3] Учётные записи"
awk -F: '$3>=1000 && $3<65534 {printf "  %s (uid=%s)\n",$1,$3}' /etc/passwd

echo "[4] Веб-сервер"
SITE_DIR="/var/www/devops-site"
CERT="/etc/ssl/certs/devops.crt"
KEY="/etc/ssl/private/devops.key"
CERT_MIN_DAYS="${CERT_MIN_DAYS:-30}"   # порог можно завысить для проверки: CERT_MIN_DAYS=400

# а) служба nginx активна
check "Служба nginx активна" "active" "$(systemctl is-active nginx 2>/dev/null)"

# б) конфигурация nginx синтаксически корректна
sudo nginx -t >/dev/null 2>&1; NGINX_T=$?
check "Конфигурация nginx корректна (nginx -t)" "0" "$NGINX_T"

# в) сертификат истекает не ранее чем через CERT_MIN_DAYS дней
openssl x509 -checkend $((CERT_MIN_DAYS * 86400)) -noout -in "$CERT" >/dev/null 2>&1; CERT_RC=$?
check "Сертификат действителен ещё не менее ${CERT_MIN_DAYS} дн. ($(openssl x509 -enddate -noout -in "$CERT" 2>/dev/null | cut -d= -f2))" "0" "$CERT_RC"

# г) нет файлов, доступных для записи всем, и права ключа равны 600
WW_COUNT="$(sudo find "$SITE_DIR" -perm -o+w 2>/dev/null | wc -l)"
KEY_MODE="$(sudo stat -c '%a' "$KEY" 2>/dev/null)"
check "Нет файлов с правом записи для всех в ${SITE_DIR}; права ключа 600" \
  "файлов o+w: 0, ключ: 600" "файлов o+w: ${WW_COUNT}, ключ: ${KEY_MODE:-нет}"

echo "[5] Контейнеризация"
APP_DIR="${APP_DIR:-/home/devops/app}"

# а) служба docker активна
check "Служба docker активна" "active" "$(systemctl is-active docker 2>/dev/null)"

# б) контейнер СУБД в состоянии healthy
check "Контейнер СУБД app-db-1 в состоянии healthy" "healthy" \
  "$(docker inspect -f '{{.State.Health.Status}}' app-db-1 2>/dev/null || echo 'нет контейнера')"

# в) порты 5000 и 5432 не прослушиваются ни на одном адресе, кроме 127.0.0.1
EXPOSED="$(ss -tlnH | awk '{print $4}' | grep -E ':(5000|5432)$' | grep -v '^127\.0\.0\.1:' | paste -sd, -)"
check "Порты 5000 и 5432 прослушиваются только на 127.0.0.1" "" "$EXPOSED"

# г) права файла .env равны 600
check "Права файла ${APP_DIR}/.env равны 600" "600" "$(stat -c '%a' "${APP_DIR}/.env" 2>/dev/null || echo 'нет файла')"

echo "[6] Контрольная работа № 2"
KR2_DIR="${KR2_DIR:-/home/devops/kr2}"
KR2_PORT="${KR2_PORT:-8003}"
KR2_CERT="/etc/ssl/certs/kr2.crt"
dc() { docker compose --project-directory "$KR2_DIR" "$@"; }

# а) контейнер сервиса redis в состоянии healthy (контейнер ищется по имени сервиса)
REDIS_CID="$(dc ps -q redis 2>/dev/null)"
check "Контейнер сервиса redis в состоянии healthy" "healthy" \
  "$( [ -n "$REDIS_CID" ] && docker inspect -f '{{.State.Health.Status}}' "$REDIS_CID" 2>/dev/null || echo 'нет контейнера')"

# б) порт приложения опубликован только на 127.0.0.1
APP_PUB="$(dc port app "$KR2_PORT" 2>/dev/null | sort -u | paste -sd, -)"
check "Порт ${KR2_PORT} опубликован только на 127.0.0.1" "127.0.0.1:${KR2_PORT}" "${APP_PUB:-не опубликован}"

# в) права файла .env равны 600
check "Права файла ${KR2_DIR}/.env равны 600" "600" "$(stat -c '%a' "${KR2_DIR}/.env" 2>/dev/null || echo 'нет файла')"

# г) сертификат kr2 истекает не ранее чем через CERT_MIN_DAYS дней
openssl x509 -checkend $((CERT_MIN_DAYS * 86400)) -noout -in "$KR2_CERT" >/dev/null 2>&1; KR2_CERT_RC=$?
check "Сертификат kr2.crt действителен ещё не менее ${CERT_MIN_DAYS} дн." "0" "$KR2_CERT_RC"

# д) ресурс kr2 активирован (символическая ссылка в sites-enabled)
check "Ресурс kr2 активирован в /etc/nginx/sites-enabled/" "ссылка на /etc/nginx/sites-available/kr2" \
  "$( [ -L /etc/nginx/sites-enabled/kr2 ] && echo "ссылка на $(readlink -f /etc/nginx/sites-enabled/kr2)" || echo 'нет ссылки')"

echo "Пройдено: $PASS, не пройдено: $FAIL"
[[ $FAIL -eq 0 ]] && exit 0 || exit 1
EOF
chmod +x scripts/audit.sh

git add app.py Dockerfile docker-compose.yml README.md requirements.txt nginx/kr2 scripts/audit.sh
git status
git commit -m "feat: sync KR2 app files, nginx site and audit script" || true
git push -u origin kr2/variant-3
echo OK: https://github.com/katshuuu/devops-kr2/pull/1
