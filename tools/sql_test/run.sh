#!/usr/bin/env bash
# Lokálny test SQL migrácií na dočasnom Postgrese (nič sa nepripája na Lovable ani na internet).
# Použitie:  tools/sql_test/run.sh SUBOR.sql [SUBOR.sql ...]
# Najprv sa spustí stub_supabase.sql a všetky migrácie drizzle/migrations/*.sql, potom zadané súbory v zadanom poradí.
# Súbor sa posiela cez štandardný vstup, takže nezáleží na právach k priečinkom. Chyba v ktoromkoľvek súbore ukončí test s kódom 1.
# Spúšťa sa ako root (použije sa používateľ postgres) alebo ako bežný používateľ, ktorý smie spustiť initdb.
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
ROOT=$(cd "$HERE/../.." && pwd)
BIN=$(dirname "$(ls /usr/lib/postgresql/*/bin/initdb | sort -V | tail -1)")
WORK=$(mktemp -d)
PORT=${PGTEST_PORT:-54329}
# Testy, ktoré potrebujú samotný skript ako text (stav_databazy.sql), ho načítajú cez `cat "$ZALOHA_DIR/..."`. psql beží pod používateľom
# postgres, ktorý nemusí vidieť priečinok repozitára, preto sa skripty skopírujú do pracovného priečinka čitateľného pre všetkých.
mkdir -p "$WORK/zaloha" && cp "$ROOT"/docs/zaloha/*.sql "$WORK/zaloha/" && chmod -R a+rX "$WORK"
export ZALOHA_DIR="$WORK/zaloha"
if [ "$(id -u)" = 0 ]; then
  chown postgres "$WORK"
  as_pg() { su postgres -s /bin/bash -c "$1"; }
else
  as_pg() { bash -c "$1"; }
fi
cleanup() { as_pg "$BIN/pg_ctl -D '$WORK/data' -m immediate stop" >/dev/null 2>&1 || true; rm -rf "$WORK"; }
trap cleanup EXIT
as_pg "$BIN/initdb -D '$WORK/data' -A trust -U postgres -E UTF8 --locale=C.UTF-8" >/dev/null
as_pg "$BIN/pg_ctl -D '$WORK/data' -o \"-p $PORT -k '$WORK' -c listen_addresses=''\" -l '$WORK/log' -w start" >/dev/null
# Výsledky dotazov sa štandardne skrývajú; PGTEST_SHOW=1 ich vypíše (užitočné pri ladení).
OUT_OPT="-o /dev/null"; [ -n "${PGTEST_SHOW:-}" ] && OUT_OPT=""
PSQL="$BIN/psql -h '$WORK' -p $PORT -U postgres -X -q $OUT_OPT -v ON_ERROR_STOP=1"
as_pg "$PSQL -d postgres -c 'CREATE DATABASE test'" >/dev/null
step() { echo "== $1"; as_pg "$PSQL -d test" < "$2"; }
step "napodobenina Supabase" "$HERE/stub_supabase.sql"
for f in "$ROOT"/drizzle/migrations/*.sql; do step "migrácia $(basename "$f")" "$f"; done
for f in "$@"; do step "$(basename "$f")" "$(cd "$(dirname "$f")" && pwd)/$(basename "$f")"; done
echo "HOTOVO: všetky kroky prebehli bez chyby"
