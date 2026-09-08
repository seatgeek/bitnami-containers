# Copyright Broadcom, Inc. All Rights Reserved.
# SPDX-License-Identifier: APACHE-2.0

FROM docker.io/bitnami/minideb:bookworm

ARG DOWNLOADS_URL="https://downloads.bitnami.com/files/stacksmith"
ARG TARGETARCH

LABEL org.opencontainers.image.base.name="docker.io/bitnami/minideb:bookworm" \
      org.opencontainers.image.created="2026-08-11T14:31:55Z" \
      org.opencontainers.image.description="Application packaged by Broadcom, Inc." \
      org.opencontainers.image.documentation="https://github.com/bitnami/containers/tree/main/bitnami/pgbouncer/README.md" \
      org.opencontainers.image.source="https://github.com/bitnami/containers/tree/main/bitnami/pgbouncer" \
      org.opencontainers.image.title="pgbouncer" \
      org.opencontainers.image.vendor="Broadcom, Inc." \
      org.opencontainers.image.version="1.25.2"

ENV HOME="/" \
    OS_ARCH="${TARGETARCH:-amd64}" \
    OS_FLAVOUR="debian-12" \
    OS_NAME="linux"

COPY prebuildfs /
SHELL ["/bin/bash", "-o", "errexit", "-o", "nounset", "-o", "pipefail", "-c"]
# Install required system packages and dependencies
RUN install_packages ca-certificates curl groff-base libaudit1 libbsd0 libbz2-1.0 libc-ares2 libcap-ng0 libedit2 libevent-2.1-7 libffi8 libgcc-s1 libgmp10 libgnutls30 libhogweed6 libicu72 libidn2-0 libldap-2.5-0 liblzma5 libmd0 libncursesw6 libnettle8 libp11-kit0 libpam0g libreadline8 libsqlite3-0 libsasl2-2 libssl3 libstdc++6 libtasn1-6 libtinfo6 libunistring2 libuuid1 libxml2 libxslt1.1 locales procps zlib1g
RUN --mount=type=secret,id=downloads_url,env=SECRET_DOWNLOADS_URL \
    DOWNLOADS_URL=${SECRET_DOWNLOADS_URL:-${DOWNLOADS_URL}} ; \
    mkdir -p /tmp/bitnami/pkg/cache/ ; cd /tmp/bitnami/pkg/cache/ || exit 1 ; \
    COMPONENTS=( \
      "nss-wrapper-1.1.16-0-linux-${OS_ARCH}-debian-12" \
      "wait-for-port-1.0.11-0-linux-${OS_ARCH}-debian-12" \
      "postgresql-client-14.23.0-0-linux-${OS_ARCH}-debian-12" \
      "ini-file-1.4.10-0-linux-${OS_ARCH}-debian-12" \
      "pgbouncer-1.25.2-1-linux-${OS_ARCH}-debian-12" \
      "python-3.14.7-5-linux-${OS_ARCH}-debian-12" \
      "aws-cli-2.36.30-0-linux-${OS_ARCH}-debian-12" \
    ) ; \
    for COMPONENT in "${COMPONENTS[@]}"; do \
      if [ ! -f "${COMPONENT}.tar.gz" ]; then \
        curl -SsLf "${DOWNLOADS_URL}/${COMPONENT}.tar.gz" -O ; \
      fi ; \
      sha256sum -c "/opt/bitnami/checksums/${COMPONENT}.tar.gz.sha256" ; \
      tar -zxf "${COMPONENT}.tar.gz" -C /opt/bitnami --strip-components=2 --no-same-owner ; \
      rm -rf "${COMPONENT}".tar.gz ; \
    done ; \
    rm -rf /opt/bitnami/checksums ;
RUN apt-get update && apt-get upgrade -y && \
    apt-get install -y inotify-tools && \
    apt-get clean && rm -rf /var/lib/apt/lists /var/cache/apt/archives
RUN mkdir -p /opt/bitnami/process-compose/bin && \
    PC_VERSION="1.122.0" && \
    curl -SsLf "https://github.com/F1bonacc1/process-compose/releases/download/v${PC_VERSION}/process-compose_linux_${OS_ARCH}.tar.gz" -o /tmp/process-compose.tar.gz && \
    if [ "$OS_ARCH" = "amd64" ]; then \
      echo "9b6dbc38324c0b0481f1cd1dd828ffdc78117129ec797678f4bf8c4023311281  /tmp/process-compose.tar.gz" | sha256sum -c - ; \
    else \
      echo "52fa7d5a2d5e0db470faec5976204fc215ed7e3d13689e930cf522becfb63778  /tmp/process-compose.tar.gz" | sha256sum -c - ; \
    fi && \
    tar -zxf /tmp/process-compose.tar.gz -C /opt/bitnami/process-compose/bin process-compose && \
    rm /tmp/process-compose.tar.gz && \
    chmod +x /opt/bitnami/process-compose/bin/process-compose
RUN chmod g+rwX /opt/bitnami
RUN find / -perm /6000 -type f -exec chmod a-s {} \; || true
RUN update-locale LANG=C.UTF-8 LC_MESSAGES=POSIX && \
    DEBIAN_FRONTEND=noninteractive dpkg-reconfigure locales && \
    echo 'en_US.UTF-8 UTF-8' >> /etc/locale.gen
RUN /opt/bitnami/scripts/locales/generate-locales.sh
RUN uninstall_packages curl

COPY rootfs /
RUN /opt/bitnami/scripts/pgbouncer/postunpack.sh
ENV APP_VERSION="1.25.2" \
    AWS_CA_BUNDLE="/etc/ssl/certs/ca-certificates.crt" \
    BITNAMI_APP_NAME="pgbouncer" \
    IMAGE_REVISION="8" \
    LANG="en_US.UTF-8" \
    LANGUAGE="en_US:en" \
    LD_LIBRARY_PATH="/opt/bitnami/postgresql/lib" \
    NSS_WRAPPER_LIB="/opt/bitnami/common/lib/libnss_wrapper.so" \
    PATH="/opt/bitnami/process-compose/bin:/opt/bitnami/python/bin:/opt/bitnami/aws-cli/bin:/opt/bitnami/aws-cli/venv/bin:/opt/bitnami/common/bin:/opt/bitnami/postgresql/bin:/opt/bitnami/pgbouncer/bin:$PATH"

EXPOSE 6432

USER 1001
ENTRYPOINT [ "/opt/bitnami/scripts/pgbouncer/entrypoint.sh" ]
CMD [ "/opt/bitnami/scripts/pgbouncer/run.sh" ]
