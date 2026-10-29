#!/opt/bitnami/aws-cli/venv/bin/python
"""Mints RDS IAM auth tokens for every "user host port" line on stdin.

Prints one PgBouncer userlist line per target. Runs in a single process, so memory no
longer grows with the number of databases the way one `aws` process per DSN did, and
credentials are resolved once and shared. Token generation is local SigV4 signing.
Uses the botocore bundled with the AWS CLI venv, since the image ships no boto3.
"""
import re
import sys

from awscli.botocore.session import Session


def host_region(host):
    """RDS embeds the region in the endpoint; aws puts it before ".rds", aws-cn after."""
    rest = host.removesuffix(".cn").removesuffix(".amazonaws.com").removesuffix(".rds")
    last = rest.rsplit(".", 1)[-1]
    return last if re.fullmatch(r"[a-z]{2}-.+-[0-9]", last) else None


def main():
    session = Session()
    clients = {}
    failed = False

    for line in sys.stdin:
        if not line.strip():
            continue
        user, host, port = line.split()
        target = f"{user}@{host}:{port}"
        try:
            region = host_region(host)
            if region not in clients:
                clients[region] = session.create_client("rds", region_name=region)
            token = clients[region].generate_db_auth_token(
                DBHostname=host, Port=int(port), DBUsername=user, Region=region
            )
        except Exception as e:  # any failure must leave no half-written userlist
            print(f"Failed to generate an IAM token for {target}: {e}", file=sys.stderr)
            failed = True
            continue

        if not token:
            print(f"Generated an empty IAM token for {target}", file=sys.stderr)
            failed = True
            continue

        print(f"Minted IAM token for {target} ({len(token)} bytes)", file=sys.stderr)
        print(f'"{user}" "{token}"')

    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
