# SeatGeek additions to the PgBouncer image

This fork adds the AWS CLI, Python, process-compose, and a supervisor under
`/opt/seatgeek/pgbouncer` to the Bitnami image. The supervisor is the image's entrypoint, so
no `command` is needed. Any arguments are executed in its place (e.g. `docker run <image>
bash`), and the upstream behavior is still available by overriding the entrypoint:

```yaml
command: ["/opt/bitnami/scripts/pgbouncer/entrypoint.sh", "/opt/bitnami/scripts/pgbouncer/run.sh"]
```

The supervisor runs PgBouncer under [process-compose](https://f1bonacc1.github.io/process-compose/launcher/)
together with the processes that keep its config current:

| Process         | What it does                                                                                   |
|-----------------|------------------------------------------------------------------------------------------------|
| `setup`         | Builds the initial config with Bitnami's `setup.sh`, then appends RDS IAM tokens               |
| `pgbouncer`     | Bitnami's `run.sh`; the container exits when it does                                            |
| `config-reload` | Rebuilds the config and issues `RELOAD` whenever `PGBOUNCER_WATCH_DIR` changes                  |
| `iam-refresh`   | Does the same every `PGBOUNCER_IAM_REFRESH_SECONDS`, well before IAM tokens expire (15 minutes) |

Both reload processes call the same script, which serializes overlapping runs with `flock`,
because process-compose cannot combine `watch` and `schedule` on one process. `RELOAD` is
issued over the unix socket in `PGBOUNCER_SOCKET_DIR` as `POSTGRESQL_USERNAME`, which Bitnami
writes into `admin_users`, so the socket must accept that user (for example a `local all all
trust` line in the HBA file).

## Image tags

Images are published as `<version>-r<IMAGE_REVISION>-sg<SEATGEEK_REVISION>`, e.g.
`1.26.0-r0-sg0`. `IMAGE_REVISION` in the Dockerfile tracks upstream Bitnami releases;
`SEATGEEK_REVISION` (next to the Dockerfile) tracks our changes. Bump `SEATGEEK_REVISION` with
every SeatGeek change and never reset it, so each tag always maps to one image.

## Environment variables

All Bitnami variables still apply. The supervisor adds:

| Variable                        | Default                                                   | Description                                                                                         |
|---------------------------------|-----------------------------------------------------------|-----------------------------------------------------------------------------------------------------|
| `PGBOUNCER_ENV_FILE`            |                                                           | Shell file sourced before every config build, e.g. a rendered file exporting `PGBOUNCER_DSN_*`     |
| `PGBOUNCER_WATCH_DIR`           | directory of `PGBOUNCER_ENV_FILE`, else of `PGBOUNCER_USERLIST_FILE`, else `/bitnami/pgbouncer/conf` | Directory whose changes trigger a rebuild and `RELOAD`                  |
| `PGBOUNCER_IAM_REFRESH_SECONDS` | `600`                                                     | Interval of the scheduled rebuild; it runs whether or not any DSN uses IAM                          |
| `PGBOUNCER_IAM_USER_PREFIX`     | `iam-user-`                                               | DSN users with this prefix get an RDS IAM token instead of a static password                        |
| `PGBOUNCER_WAIT_FOR_BACKEND`    | `yes`                                                     | Set to `no` to skip Bitnami's wait for `POSTGRESQL_HOST`, e.g. when that host is PgBouncer itself   |

`PGBOUNCER_USERLIST_FILE` is re-read on every rebuild, so rotating static credentials in that
file takes effect without a restart.

## RDS IAM authentication

A DSN opts in by convention: its `user=` carries `PGBOUNCER_IAM_USER_PREFIX` and its `host=` is
an RDS endpoint (`*.rds.amazonaws.com` or `*.rds.*.amazonaws.com.cn`).

```sh
export PGBOUNCER_DSN_0="api=host=db-api.abc123.us-east-1.rds.amazonaws.com port=5432 user=iam-user-api dbname=api"
```

On each build the supervisor mints a token per matching DSN with `aws rds generate-db-auth-token`
(region taken from the endpoint), before `setup.sh` deletes the old userlist, and appends it to
`userlist.txt`. Prefixed lines from the static userlist are dropped so they cannot shadow a fresh
token. A prefixed user pointing at a non-RDS host gets no token and a warning.

When IAM DSNs are present, `PGBOUNCER_SERVER_TLS_SSLMODE` values weaker than `require` are
upgraded to `require`, since RDS IAM rejects unencrypted connections. The setting is
process-wide in PgBouncer.

The container's IAM role needs [`rds-db:connect`](https://docs.aws.amazon.com/AmazonRDS/latest/UserGuide/UsingWithRDS.IAMDBAuth.IAMPolicy.html)
for the database user, and that user must be granted `rds_iam` in Postgres.

## Logging

process-compose writes each process's output as JSON to a fifo. `log-filter.py` reads it,
drops the always-zero `replica` field, strips Bitnami ANSI prefixes, maps embedded Bitnami
(`INFO`/`WARN`/`ERROR`) and PgBouncer (`LOG`/`WARNING`/`FATAL`/...) severities into `level`,
and writes one JSON object per line to container stdout:

```json
{"time":"2026-09-25T01:45:05.885338498Z","level":"info","process":"pgbouncer","message":"listening on 0.0.0.0:5432"}
```

Everything goes to stdout, because many log collectors mark the stderr stream as an error
regardless of content. process-compose's own text log and its `[process]`-prefixed echo
on fd 1 are discarded.
