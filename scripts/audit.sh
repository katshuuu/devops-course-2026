#!/usr/bin/env bash
# Аудит защиты сервера devops-vm (ПР5–ПР8 / КР2).
# Использование: sudo bash audit.sh [--stage ssh|web|docker|kr2] [минимум_дней]
set -uo pipefail

export LC_ALL=C
PASS=0
FAIL=0
stage=kr2
cert_min_days="${CERT_MIN_DAYS:-30}"

while (( $# )); do
  case "$1" in
    --stage)
      if (( $# < 2 )); then
        printf 'Нужно указать этап: ssh, web, docker или kr2.\n' >&2
        exit 1
      fi
      stage="$2"
      shift 2
      ;;
    [0-9]*) cert_min_days="$1"; shift ;;
    *) printf 'Использование: audit.sh [--stage ssh|web|docker|kr2] [минимум_дней]\n' >&2; exit 1 ;;
  esac
done

case "$stage" in
  ssh|web|docker|kr2) ;;
  *) printf 'Неизвестный этап аудита: %s\n' "$stage" >&2; exit 1 ;;
esac

if [[ ! "$cert_min_days" =~ ^[0-9]+$ ]] || (( cert_min_days > 36500 )); then
  printf 'Минимальный срок должен быть целым числом от 0 до 36500.\n' >&2
  exit 1
fi

check() {
  local desc="$1" expected="$2" actual="$3"
  if [[ "$actual" == "$expected" ]]; then
    printf '  [OK]   %s\n' "$desc"
    ((PASS += 1))
  else
    printf "  [FAIL] %s (ожидалось: '%s', получено: '%s')\n" "$desc" "$expected" "$actual"
    ((FAIL += 1))
  fi
}

if ! sudo -v; then
  printf 'Не удалось получить права sudo для аудита.\n' >&2
  exit 1
fi

printf 'Аудит конфигурации: %s, %s\n' "$(hostname -f 2>/dev/null || hostname)" "$(date '+%Y-%m-%d %H:%M')"

printf '[1] Служба SSH\n'
ssh_config="$(sudo /usr/sbin/sshd -T)"
check 'Вход от имени root запрещён' 'no' "$(awk '/^permitrootlogin / {print $2}' <<< "$ssh_config")"
check 'Парольная аутентификация отключена' 'no' "$(awk '/^passwordauthentication / {print $2}' <<< "$ssh_config")"
port="$(awk '/^port / {print $2; exit}' <<< "$ssh_config")"
nonstandard_port=no
if [[ "$port" =~ ^[0-9]+$ && "$port" != 22 ]]; then
  nonstandard_port=yes
fi
check 'SSH использует нестандартный порт' 'yes' "$nonstandard_port"
check 'MaxAuthTries равно 3' '3' "$(awk '/^maxauthtries / {print $2}' <<< "$ssh_config")"

printf '[2] Межсетевой экран\n'
check 'Межсетевой экран активен' 'active' "$(sudo ufw status | awk '/^Status:/ {print $2}')"
check 'Входящие соединения по умолчанию запрещены' 'deny' "$(sudo ufw status verbose | awk '/^Default:/ {print $2}')"

printf '[3] Учётные записи\n'
awk -F: '$3 >= 1000 && $3 < 65534 {printf "    %s (uid=%s)\n", $1, $3}' /etc/passwd

if [[ "$stage" != ssh ]]; then
  printf '[4] Веб-сервер\n'
  check 'Служба Nginx активна' 'active' "$(systemctl is-active nginx)"
  sudo nginx -t >/dev/null 2>&1
  check 'Конфигурация Nginx корректна' '0' "$?"
  openssl x509 -in /etc/ssl/certs/devops.crt -noout -checkend "$((cert_min_days * 86400))" >/dev/null 2>&1
  check "Сертификат devops.crt действует минимум ${cert_min_days} дней" '0' "$?"
  unsafe_files="$(find /var/www/devops-site -perm -o+w -print 2>/dev/null || true)"
  key_mode="$(sudo stat -c '%a' /etc/ssl/private/devops.key 2>/dev/null || echo missing)"
  permissions_ok=no
  if [[ -z "$unsafe_files" && "$key_mode" == 600 ]]; then
    permissions_ok=yes
  fi
  check 'Нет записи для всех и ключ devops имеет права 600' 'yes' "$permissions_ok"
fi

if [[ "$stage" == docker || "$stage" == kr2 ]]; then
  printf '[5] Контейнеризация\n'
  check 'Служба Docker активна' 'active' "$(systemctl is-active docker)"
  check 'СУБД app-db-1 в состоянии healthy' 'healthy' "$(sudo docker inspect -f '{{.State.Health.Status}}' app-db-1 2>/dev/null || echo missing)"
  listeners="$(ss -H -tln 2>/dev/null || true)"
  ports_ok=no
  unsafe_listeners="$(awk '$4 ~ /:(5000|5432)$/ && $4 !~ /^127[.]0[.]0[.]1:(5000|5432)$/ {print $4}' <<< "$listeners")"
  if [[ -z "$unsafe_listeners" ]]; then
    ports_ok=yes
  fi
  check 'Порты 5000 и 5432 не опубликованы за пределами loopback' 'yes' "$ports_ok"
  check 'Файл /home/devops/app/.env имеет права 600' '600' "$(sudo stat -c '%a' /home/devops/app/.env 2>/dev/null || echo missing)"
fi

if [[ "$stage" == kr2 ]]; then
  printf '[6] Контрольная работа № 2\n'
  KR2_DIR="${KR2_DIR:-/home/devops/kr2}"
  KR2_PORT="${KR2_PORT:-8003}"
  KR2_CERT="/etc/ssl/certs/kr2.crt"
  dc() { sudo docker compose --project-directory "$KR2_DIR" "$@"; }
  REDIS_CID="$(dc ps -q redis 2>/dev/null || true)"
  check 'Контейнер сервиса redis в состоянии healthy' 'healthy' \
    "$( [ -n "$REDIS_CID" ] && sudo docker inspect -f '{{.State.Health.Status}}' "$REDIS_CID" 2>/dev/null || echo 'нет контейнера')"
  APP_PUB="$(dc port app "$KR2_PORT" 2>/dev/null | sort -u | paste -sd, - || true)"
  check "Порт ${KR2_PORT} опубликован только на 127.0.0.1" "127.0.0.1:${KR2_PORT}" "${APP_PUB:-не опубликован}"
  check "Права файла ${KR2_DIR}/.env равны 600" '600' "$(sudo stat -c '%a' "${KR2_DIR}/.env" 2>/dev/null || echo 'нет файла')"
  openssl x509 -checkend $((cert_min_days * 86400)) -noout -in "$KR2_CERT" >/dev/null 2>&1
  KR2_CERT_RC=$?
  check "Сертификат kr2.crt действителен ещё не менее ${cert_min_days} дн." '0' "$KR2_CERT_RC"
  if [[ -L /etc/nginx/sites-enabled/kr2 ]]; then
    kr2_link="ссылка на $(readlink -f /etc/nginx/sites-enabled/kr2)"
  else
    kr2_link='нет ссылки'
  fi
  check 'Ресурс kr2 активирован в /etc/nginx/sites-enabled/' 'ссылка на /etc/nginx/sites-available/kr2' "$kr2_link"
fi

printf 'Пройдено: %s, не пройдено: %s\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]] && exit 0 || exit 1
