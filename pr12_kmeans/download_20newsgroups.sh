#!/usr/bin/env bash
# Загрузка корпуса 20 Newsgroups для задания 3 ПР-12.
# Исходный http://cmj4.web.rice.edu/KMeans.zip недоступен (forbidden),
# поэтому берём эквивалентное зеркало 20news-18828.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")" && pwd)"
DEST="$ROOT/KMeans/20_Newsgroups"
URL="http://qwone.com/~jason/20Newsgroups/20news-18828.tar.gz"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

if [[ -d "$DEST" ]] && [[ "$(find "$DEST" -type f | wc -l)" -gt 1000 ]]; then
  echo "Уже есть: $DEST"
  exit 0
fi

mkdir -p "$ROOT/KMeans"
echo "Скачиваю $URL ..."
curl -L --fail --max-time 600 -o "$TMP/20news.tar.gz" "$URL"
tar -xzf "$TMP/20news.tar.gz" -C "$TMP"
rm -rf "$DEST"
mv "$TMP/20news-18828" "$DEST"
echo "Готово: $DEST ($(find "$DEST" -type f | wc -l) файлов, $(ls -1 "$DEST" | wc -l) групп)"
