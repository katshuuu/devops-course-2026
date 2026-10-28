#!/usr/bin/env bash
# Доставка статического сайта: scripts/deploy.sh [--dry-run]
set -euo pipefail
REMOTE="${REMOTE:-devops}"
REMOTE_DIR="/var/www/devops-site"
SITE_URL="${SITE_URL:-https://devops.local}"
CA_CERT="${CA_CERT:-${HOME}/devops.crt}"
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
LOCAL_DIR="${ROOT}/site/"
DRY_RUN=false
if [[ $# -gt 1 || ( $# -eq 1 && "$1" != --dry-run ) ]]; then
    echo 'Использование: deploy.sh [--dry-run]' >&2
    exit 1
fi
if [[ $# -eq 1 ]]; then
    DRY_RUN=true
    set -- --dry-run
else
    set --
fi
if [[ ! -f "${LOCAL_DIR}index.html" ]]; then
    echo 'Ошибка: site/index.html отсутствует; доставка отменена.' >&2
    exit 1
fi
if [[ -n "$(git -C "$ROOT" status --porcelain --untracked-files=normal)" ]]; then
    echo 'Ошибка: есть незафиксированные изменения; доставка отменена.' >&2
    exit 1
fi
if ! rsync -avz --delete --chmod=Du=rwx,Dgo=rx,Fu=rw,Fgo=r "$@" \
    -e 'ssh -o BatchMode=yes -o ConnectTimeout=5' \
    "$LOCAL_DIR" "${REMOTE}:${REMOTE_DIR}/"; then
    echo 'Ошибка синхронизации.' >&2
    exit 1
fi
if "$DRY_RUN"; then
    echo 'Пробный запуск завершён; сервер не изменён.'
    exit 0
fi
if ! curl -fsS --connect-timeout 5 --max-time 15 --cacert "$CA_CERT" "$SITE_URL" >/dev/null; then
    echo 'Ошибка проверки HTTPS после доставки.' >&2
    exit 1
fi
printf 'Доставлен коммит %s\n' "$(git -C "$ROOT" rev-parse --short HEAD)"
