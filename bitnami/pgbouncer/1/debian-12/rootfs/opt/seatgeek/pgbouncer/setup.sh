#!/bin/bash

# shellcheck disable=SC1091

set -o errexit
set -o nounset
set -o pipefail

. /opt/seatgeek/pgbouncer/lib.sh
. /opt/bitnami/scripts/libbitnami.sh
. /opt/bitnami/scripts/liblog.sh

info "** Starting PgBouncer setup **"
apply_pgbouncer_config
info "** PgBouncer setup finished! **"
