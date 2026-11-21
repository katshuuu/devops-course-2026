#!/usr/bin/env bash
# Атомарная доставка статического ресурса с возможностью отката (факультативное задание ПР6)
# Использование: scripts/deploy-atomic.sh [--rollback]
# Структура на сервере:
#   /var/www/devops-site/releases/<ГГГГММДД-ЧЧММСС>/   — версии
#   /var/www/devops-site/current -> releases/<...>      — root в nginx
set -euo pipefail

REMOTE="devops"
BASE="/var/www/devops-site"
SITE_URL="https://devops.local"
CA_CERT="${HOME}/devops.crt"
KEEP=5
SSH=(ssh -o BatchMode=yes -o ConnectTimeout=5)

err() { echo "deploy-atomic: $*" >&2; }
cd "$(git rev-parse --show-toplevel)"

# --- Откат: одно SSH-соединение ---------------------------------------------
if [[ "${1:-}" == "--rollback" ]]; then
  "${SSH[@]}" "${REMOTE}" bash -s -- "${BASE}" <<'EOS'
set -euo pipefail
cd "$1"
cur="$(readlink current)"
prev="$(ls -1d releases/*/ | sed 's:/$::' | sort | grep -B1 -x "${cur}" | head -n1)"
if [[ -z "${prev}" || "${prev}" == "${cur}" ]]; then
  echo "deploy-atomic: предыдущей версии нет" >&2; exit 1
fi
ln -s "${prev}" current_tmp && mv -T current_tmp current
echo "Откат: current -> ${prev} (было ${cur})"
EOS
  exit 0
elif [[ -n "${1:-}" ]]; then
  err "неизвестный аргумент '${1}'"; exit 1
fi

# --- Доставка новой версии: два SSH-соединения ------------------------------
[[ -f site/index.html ]] || { err "site/index.html отсутствует"; exit 1; }
[[ -z "$(git status --porcelain)" ]] || { err "есть незафиксированные изменения"; exit 1; }

REL="$(date -u +%Y%m%d-%H%M%S)"
COMMIT="$(git rev-parse --short HEAD)"

# Соединение 1: новая версия в отдельный каталог; неизменённые файлы
# не передаются, а создаются жёсткими ссылками на файлы текущей версии.
rsync -az --mkpath --chmod=D755,F644 -e "${SSH[*]}" \
  --link-dest="${BASE}/current/" \
  site/ "${REMOTE}:${BASE}/releases/${REL}/"

# Соединение 2: атомарное переключение и удаление старых версий
"${SSH[@]}" "${REMOTE}" bash -s -- "${BASE}" "${REL}" "${KEEP}" <<'EOS'
set -euo pipefail
cd "$1"
chmod 755 releases
ln -s "releases/$2" current_tmp
mv -T current_tmp current            # rename(2): атомарная замена ссылки
ls -1d releases/*/ | sed 's:/$::' | sort | head -n -"$3" | xargs -r rm -rf
echo "current -> $(readlink current); версий: $(ls -1d releases/*/ | wc -l)"
EOS

curl -fsS --cacert "${CA_CERT}" --max-time 10 -o /dev/null "${SITE_URL}/" \
  || { err "ресурс недоступен после переключения; откат: $0 --rollback"; exit 1; }
echo "Готово: коммит ${COMMIT} опубликован как releases/${REL}"
