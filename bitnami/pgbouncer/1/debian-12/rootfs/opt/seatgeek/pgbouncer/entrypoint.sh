#!/bin/bash
# Runs PgBouncer under process-compose alongside the processes that keep its config
# current: a watcher that rebuilds and RELOADs when PGBOUNCER_WATCH_DIR changes, and
# a scheduled refresh that re-mints RDS IAM tokens before they expire.

# shellcheck disable=SC1091

set -o errexit
set -o nounset
set -o pipefail

. /opt/seatgeek/pgbouncer/lib.sh

pgbouncer_supervisor_env
pgbouncer_source_env_file

# pgbouncer-env.sh reads *_FILE vars and unsets them; keep the path so each config
# rebuild can restore it and pick up changes to the file.
export PGBOUNCER_SUPERVISOR_USERLIST_FILE="${PGBOUNCER_USERLIST_FILE:-}"

. /opt/bitnami/scripts/pgbouncer-env.sh

. /opt/bitnami/scripts/libbitnami.sh
. /opt/bitnami/scripts/liblog.sh
. /opt/bitnami/scripts/libpgbouncer.sh

pgbouncer_enable_nss_wrapper
pgbouncer_log_filter

# process-compose echoes process output to fd 1 with a "[name]" prefix in headless
# mode and there is no switch to turn that off. Discard fd 1; JSON goes to the fifo.
# Internal text logs go to /dev/null so they do not mix with the JSON stream.
exec process-compose \
  --disable-dotenv \
  --no-server \
  --log-no-color \
  --log-file /dev/null \
  -f "${PGBOUNCER_SUPERVISOR_DIR}/process-compose.yaml" \
  up >/dev/null
