#!/usr/bin/env bash
# Доставка статического ресурса на devops-vm
# Использование: scripts/deploy.sh [--dry-run]
set -euo pipefail

REMOTE="devops"                      # псевдоним из ~/.ssh/config (ПР № 5, шаг 1.6)
REMOTE_DIR="/var/www/devops-site"
SITE_URL="https://devops.local"
CA_CERT="${HOME}/devops.crt"
LOCAL_DIR="$(git rev-parse --show-toplevel)/site/"

# Одно SSH-соединение на запуск (rsync), без интерактивного запроса пароля:
# при непригодном ключе ssh завершается ошибкой сразу (требования 8 и 9).
SSH_CMD="ssh -o BatchMode=yes -o ConnectTimeout=5"
RSYNC_OPTS=(-avz --delete --chmod=D755,F644 -e "${SSH_CMD}")

err() { echo "deploy: $*" >&2; }

# 1. Разбор аргумента --dry-run
DRY_RUN=0
case "${1:-}" in
  "")         ;;
  --dry-run)  DRY_RUN=1 ;;
  *)          err "неизвестный аргумент '${1}'"; echo "Использование: $0 [--dry-run]" >&2; exit 1 ;;
esac
if [[ $# -gt 1 ]]; then
  err "ожидается не более одного аргумента"; exit 1
fi

# Требование 2: одинаковая работа из любого каталога репозитория
cd "$(git rev-parse --show-toplevel)"

# 2. Проверки по требованиям 4 и 5
if [[ ! -f "${LOCAL_DIR}index.html" ]]; then
  err "файл site/index.html отсутствует — доставка отменена (--delete удалил бы главную страницу)"
  exit 1
fi

if [[ -n "$(git status --porcelain)" ]]; then
  err "в репозитории есть незафиксированные изменения — доставка отменена:"
  git status --short >&2
  exit 1
fi

if [[ ${DRY_RUN} -eq 0 && ! -r "${CA_CERT}" ]]; then
  err "сертификат ${CA_CERT} не найден — проверка доступности невозможна"
  exit 1
fi

COMMIT="$(git rev-parse --short HEAD)"

# 3. Синхронизация каталога ${LOCAL_DIR} на ${REMOTE}:${REMOTE_DIR}
# 4. При --dry-run — завершение с кодом 0 без проверки доступности
if [[ ${DRY_RUN} -eq 1 ]]; then
  echo "План доставки коммита ${COMMIT} (сервер не изменяется):"
  if ! rsync "${RSYNC_OPTS[@]}" --dry-run "${LOCAL_DIR}" "${REMOTE}:${REMOTE_DIR}/"; then
    err "rsync завершился ошибкой"; exit 1
  fi
  exit 0
fi

echo "Доставка коммита ${COMMIT} на ${REMOTE}:${REMOTE_DIR}"
if ! rsync "${RSYNC_OPTS[@]}" "${LOCAL_DIR}" "${REMOTE}:${REMOTE_DIR}/"; then
  err "rsync завершился ошибкой"; exit 1
fi

# 5. Проверка доступности ${SITE_URL} с проверкой сертификата (без -k)
if ! curl -fsS --cacert "${CA_CERT}" --max-time 10 -o /dev/null "${SITE_URL}/"; then
  err "ресурс ${SITE_URL} недоступен после доставки"
  exit 1
fi

echo "Готово: доставлен коммит ${COMMIT}, ${SITE_URL} отвечает"
