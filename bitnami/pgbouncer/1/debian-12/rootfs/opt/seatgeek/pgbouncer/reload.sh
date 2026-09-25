#!/bin/bash

# shellcheck disable=SC1091

set -o errexit
set -o nounset
set -o pipefail

. /opt/seatgeek/pgbouncer/lib.sh

# setup already built the initial config; the first config-reload run is only to arm
# process-compose file watching, not to mint IAM tokens again.
if [ "${SKIP_INITIAL:-}" = "1" ] && [ ! -f /tmp/pgbouncer-reload-armed ]; then
  touch /tmp/pgbouncer-reload-armed
  exit 0
fi

# config-reload and iam-refresh share this script; serialize overlapping runs.
exec 200>/tmp/pgbouncer-reload.lock
flock 200

if ! apply_pgbouncer_config; then
  echo "failed to rebuild PgBouncer config" >&2
  exit 1
fi

if ! reload_pgbouncer; then
  echo "PgBouncer config rebuilt but RELOAD failed" >&2
  exit 1
fi
