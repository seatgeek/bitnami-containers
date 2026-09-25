#!/bin/bash
# Shared helpers for the SeatGeek PgBouncer supervisor. The entrypoint sources this
# once before handing off to process-compose; the setup and reload scripts source it
# again so they can call the helpers independently.

# shellcheck disable=SC1090,SC1091

set -o errexit
set -o nounset
set -o pipefail

export PGBOUNCER_SUPERVISOR_DIR="/opt/seatgeek/pgbouncer"

# Exports the defaults every process-compose child relies on. Values already present
# in the environment win, so the caller can override any of them.
pgbouncer_supervisor_env() {
  # Bitnami runs as a non-root user without a home directory; the AWS CLI writes
  # config under $HOME/.aws and fails with "Permission denied: '/.aws'" when HOME
  # is unset or not writable.
  export HOME=/tmp
  mkdir -p "${HOME}/.aws"

  # process-compose logs to /tmp/process-compose-$USER.log and warns when unset.
  export USER="${USER:-pgbouncer}"

  # Silence optional XDG config-home lookups (shortcuts, themes, etc.).
  export PROC_COMP_CONFIG=/tmp/.config/process-compose
  mkdir -p "${PROC_COMP_CONFIG}"

  export PGBOUNCER_LOG_FIFO=/tmp/pgbouncer-process-compose.log.fifo

  # The log filter parses Bitnami log lines; color codes only get in the way.
  export BITNAMI_COLOR=false

  # Optional shell file sourced before every config build, e.g. a templated file
  # exporting PGBOUNCER_DSN_* variables.
  export PGBOUNCER_ENV_FILE="${PGBOUNCER_ENV_FILE:-}"

  # Directory whose changes trigger a config rebuild and RELOAD. Defaults to wherever
  # the rendered inputs live.
  if [ -z "${PGBOUNCER_WATCH_DIR:-}" ]; then
    if [ -n "${PGBOUNCER_ENV_FILE}" ]; then
      PGBOUNCER_WATCH_DIR="$(dirname "${PGBOUNCER_ENV_FILE}")"
    elif [ -n "${PGBOUNCER_USERLIST_FILE:-}" ]; then
      PGBOUNCER_WATCH_DIR="$(dirname "${PGBOUNCER_USERLIST_FILE}")"
    else
      PGBOUNCER_WATCH_DIR="/bitnami/pgbouncer/conf"
    fi
  fi
  export PGBOUNCER_WATCH_DIR

  export PGBOUNCER_IAM_REFRESH_SECONDS="${PGBOUNCER_IAM_REFRESH_SECONDS:-600}"
  export PGBOUNCER_IAM_USER_PREFIX="${PGBOUNCER_IAM_USER_PREFIX:-iam-user-}"

  # Bitnami waits for POSTGRESQL_HOST:POSTGRESQL_PORT before writing the config. When
  # that host is PgBouncer itself (a sidecar fronting only PGBOUNCER_DSN_* databases)
  # the wait can never succeed, so allow replacing wait-for-port with a no-op.
  export PGBOUNCER_WAIT_FOR_BACKEND="${PGBOUNCER_WAIT_FOR_BACKEND:-yes}"
  case "${PGBOUNCER_WAIT_FOR_BACKEND}" in
    no | false | 0)
      mkdir -p /tmp/bin
      printf '#!/bin/sh\nexit 0\n' >/tmp/bin/wait-for-port
      chmod +x /tmp/bin/wait-for-port
      case ":${PATH}:" in *:/tmp/bin:*) ;; *) export PATH="/tmp/bin:${PATH}" ;; esac
      ;;
  esac
}

pgbouncer_source_env_file() {
  if [ -n "${PGBOUNCER_ENV_FILE:-}" ]; then
    . "${PGBOUNCER_ENV_FILE}"
  fi
}

# RDS embeds the region in the endpoint, but the segment order differs between
# partitions: aws puts it before ".rds", aws-cn after it. Stripping the known
# suffixes leaves the region as the final segment either way.
rds_host_region() {
  local rest="${1%.cn}"
  rest="${rest%.amazonaws.com}"
  rest="${rest%.rds}"

  case "${rest##*.}" in
    [a-z][a-z]-*-[0-9]) echo "${rest##*.}" ;;
  esac
}

# A DSN opts into IAM auth by convention rather than configuration: a user carrying
# PGBOUNCER_IAM_USER_PREFIX pointing at an RDS endpoint. Emits "user host port" per
# match, so callers can test for an empty result to detect "no IAM here".
iam_dsn_targets() {
  local i=0 var field user host port

  while var="PGBOUNCER_DSN_${i}"; [ -n "${!var:-}" ]; do
    i=$((i + 1))
    user="" host="" port="5432"

    # Drop the leading "alias=" so it cannot be read as a connection field
    for field in ${!var#*=}; do
      case "$field" in
        user=*) user="${field#user=}" ;;
        host=*) host="${field#host=}" ;;
        port=*) port="${field#port=}" ;;
      esac
    done

    case "$user" in "${PGBOUNCER_IAM_USER_PREFIX}"*) ;; *) continue ;; esac

    case "$host" in
      *.rds.amazonaws.com | *.rds.*.amazonaws.com.cn)
        echo "$user $host $port"
        ;;
      *)
        echo "not requesting an IAM token for ${user}: ${host} is not an RDS endpoint" >&2
        ;;
    esac
  done
}

# Reads "user host port" lines and emits a userlist line per target.
iam_userlist_lines() {
  local user host port region token
  local region_args=()

  while read -r user host port; do
    region=$(rds_host_region "$host")
    region_args=()
    if [ -n "$region" ]; then
      region_args=(--region "$region")
    fi

    # errexit does not fire on a failed command substitution, so both the exit
    # status and the token have to be checked to avoid writing an empty password
    if ! token=$(aws rds generate-db-auth-token \
      --hostname "$host" --port "$port" --username "$user" \
      "${region_args[@]}"); then
      echo "failed to generate an IAM token for ${user}@${host}:${port}" >&2
      return 1
    fi

    if [ -z "$token" ]; then
      echo "generated an empty IAM token for ${user}@${host}:${port}" >&2
      return 1
    fi

    echo "minted IAM token for ${user}@${host}:${port} (${#token} bytes)" >&2

    # PgBouncer silently truncates at MAX_PASSWORD, which would leave a
    # corrupt token in the userlist instead of failing outright
    if [ "${#token}" -ge 2048 ]; then
      echo "IAM token for ${user}@${host} is ${#token} bytes, over PgBouncer's 2048 byte password limit" >&2
      return 1
    fi

    printf '"%s" "%s"\n' "$user" "$token"
  done
}

# RELOAD makes PgBouncer re-read pgbouncer.ini and userlist.txt without dropping
# transactions. POSTGRESQL_USERNAME is what Bitnami writes into admin_users.
reload_pgbouncer() {
  PGPASSWORD="${POSTGRESQL_PASSWORD:-}" psql -q \
    --host="${PGBOUNCER_SOCKET_DIR}" --port="${PGBOUNCER_PORT}" \
    --dbname=pgbouncer --username="${POSTGRESQL_USERNAME}" -c 'RELOAD'
}

# Rebuilds the PgBouncer config from the current inputs. Static credentials come from
# PGBOUNCER_USERLIST_FILE, which setup.sh writes into userlist.txt. IAM tokens cannot
# go there: they are short-lived and must be minted on each refresh, so they are
# appended to userlist.txt after setup.sh runs.
apply_pgbouncer_config() {
  local targets iam_lines=""

  pgbouncer_source_env_file

  # pgbouncer-env.sh consumes PGBOUNCER_USERLIST_FILE and unsets it, so setup.sh
  # would otherwise regenerate userlist.txt from the snapshot taken at startup and
  # ignore every later change to the file.
  if [ -n "${PGBOUNCER_SUPERVISOR_USERLIST_FILE:-}" ]; then
    export PGBOUNCER_USERLIST_FILE="${PGBOUNCER_USERLIST_FILE:-$PGBOUNCER_SUPERVISOR_USERLIST_FILE}"
  fi

  targets=$(iam_dsn_targets)

  # RDS IAM rejects unencrypted connections, so anything weaker than "require" is
  # upgraded when IAM DSNs are present. The setting is process-wide in PgBouncer.
  if [ -n "$targets" ]; then
    case "${PGBOUNCER_SERVER_TLS_SSLMODE:-disable}" in
      disable | allow | prefer) export PGBOUNCER_SERVER_TLS_SSLMODE=require ;;
    esac
  fi

  # Mint before setup.sh, which deletes userlist.txt up front: a failed AWS call
  # after that point would leave PgBouncer with no IAM credentials at all.
  if [ -n "$targets" ]; then
    iam_lines=$(iam_userlist_lines <<<"$targets") || return 1
  fi

  /opt/bitnami/scripts/pgbouncer/setup.sh

  if [ -n "$iam_lines" ]; then
    # PgBouncer uses the first matching auth_file entry; drop any prefixed lines the
    # static userlist may carry so they cannot shadow a freshly minted token.
    sed -i "/^\"${PGBOUNCER_IAM_USER_PREFIX}/d" "${PGBOUNCER_AUTH_FILE:?}"
    printf '%s\n' "$iam_lines" >>"${PGBOUNCER_AUTH_FILE:?}"
  fi
}

# Background reader: process-compose writes JSON to PGBOUNCER_LOG_FIFO; the filter
# strips replica, ANSI codes, and Bitnami/PgBouncer prefixes, and maps embedded
# severity to the JSON level field. Restart the reader if it exits so writers do
# not block on a full fifo.
pgbouncer_log_filter() {
  rm -f "${PGBOUNCER_LOG_FIFO}"
  mkfifo "${PGBOUNCER_LOG_FIFO}"

  # Preserve container stdout before process-compose exec replaces the shell.
  exec 3>&1
  (
    while true; do
      python3 -u "${PGBOUNCER_SUPERVISOR_DIR}/log-filter.py" \
        <"${PGBOUNCER_LOG_FIFO}" >&3 || sleep 0.1
    done
  ) &
}
