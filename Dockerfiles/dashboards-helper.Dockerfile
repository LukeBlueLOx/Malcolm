ARG TARGETPLATFORM=linux/amd64

FROM --platform=${TARGETPLATFORM} debian:12-slim

# Copyright (c) 2020 Battelle Energy Alliance, LLC.  All rights reserved.
LABEL maintainer="malcolm@inl.gov"
LABEL org.opencontainers.image.authors='malcolm@inl.gov'
LABEL org.opencontainers.image.url='https://github.com/idaholab/Malcolm'
LABEL org.opencontainers.image.documentation='https://github.com/idaholab/Malcolm/blob/main/README.md'
LABEL org.opencontainers.image.source='https://github.com/idaholab/Malcolm'
LABEL org.opencontainers.image.vendor='Idaho National Laboratory'
LABEL org.opencontainers.image.title='ghcr.io/idaholab/malcolm/dashboards-helper'
LABEL org.opencontainers.image.description='Malcolm container providing OpenSearch Dashboards support functions'

ARG DEFAULT_UID=1000
ARG DEFAULT_GID=1000
ENV DEFAULT_UID $DEFAULT_UID
ENV DEFAULT_GID $DEFAULT_GID
ENV PUSER "helper"
ENV PGROUP "helper"
ENV PUSER_PRIV_DROP true

ENV TERM xterm

ARG CREATE_OS_ARKIME_SESSION_INDEX="true"
ARG ISM_SNAPSHOT_COMPRESSED=false
ARG ISM_SNAPSHOT_REPO=logs
ARG OFFLINE_REGION_MAPS_PORT="28991"
ARG OPENSEARCH_DEFAULT_DASHBOARD="0ad3d7c2-3441-485e-9dfe-dbb22e84e576"
ARG DASHBOARDS_DARKMODE="true"

ENV CREATE_OS_ARKIME_SESSION_INDEX $CREATE_OS_ARKIME_SESSION_INDEX
ENV ISM_SNAPSHOT_COMPRESSED $ISM_SNAPSHOT_COMPRESSED
ENV ISM_SNAPSHOT_REPO $ISM_SNAPSHOT_REPO
ENV OFFLINE_REGION_MAPS_PORT $OFFLINE_REGION_MAPS_PORT
ENV OPENSEARCH_DEFAULT_DASHBOARD $OPENSEARCH_DEFAULT_DASHBOARD
ENV DASHBOARDS_DARKMODE $DASHBOARDS_DARKMODE
ENV PATH="/data:${PATH}"

ENV SUPERCRONIC_VERSION "0.2.30"
ENV SUPERCRONIC_URL "https://github.com/aptible/supercronic/releases/download/v$SUPERCRONIC_VERSION/supercronic-linux-"
ENV SUPERCRONIC_CRONTAB "/etc/crontab"

ENV ECS_RELEASES_URL "https://api.github.com/repos/elastic/ecs/releases/latest"

ADD dashboards/dashboards /opt/dashboards
ADD dashboards/anomaly_detectors /opt/anomaly_detectors
ADD dashboards/alerting /opt/alerting
ADD dashboards/notifications /opt/notifications
ADD dashboards/maps /opt/maps
ADD dashboards/scripts /data/
ADD dashboards/supervisord.conf /etc/supervisord.conf
ADD dashboards/templates /opt/templates
COPY --chmod=755 shared/bin/docker-uid-gid-setup.sh /usr/local/bin/
COPY --chmod=755 shared/bin/service_check_passthrough.sh /usr/local/bin/
COPY --from=ghcr.io/mmguero-dev/gostatic --chmod=755 /goStatic /usr/bin/goStatic
COPY --chmod=755 shared/bin/opensearch_status.sh /data/
COPY --chmod=755 shared/bin/opensearch_index_size_prune.py /data/
COPY --chmod=755 shared/bin/opensearch_read_only.py /data/
ADD scripts/malcolm_utils.py /data/

RUN export BINARCH=$(uname -m | sed 's/x86_64/amd64/' | sed 's/aarch64/arm64/') && \
    apt-get -q update && \
    apt-get -y -q --no-install-recommends upgrade && \
    apt-get -y -q --allow-downgrades --allow-remove-essential --allow-change-held-packages install --no-install-recommends \
      bash \
      curl \
      jq \
      moreutils \
      openssl \
      procps \
      psmisc \
      python3 \
      python3-pip \
      rsync \
      tini && \
    pip3 install --break-system-packages supervisor humanfriendly requests && \
    curl -fsSL -o /usr/local/bin/supercronic "${SUPERCRONIC_URL}${BINARCH}" && \
      chmod +x /usr/local/bin/supercronic && \
    groupadd --gid ${DEFAULT_GID} ${PUSER} && \
      useradd -M --uid ${DEFAULT_UID} --gid ${DEFAULT_GID} -d /nonexistant -s /sbin/nologin ${PUSER} && \
      usermod -a -G tty ${PUSER} && \
    mkdir -p /data/init /opt/ecs && \
      cd /opt && \
      curl -sSL "$(curl -sSL "$ECS_RELEASES_URL" | jq '.tarball_url' | tr -d '"')" | tar xzf - -C ./ecs --strip-components 1 && \
      mv /opt/ecs/generated/elasticsearch /opt/ecs-templates && \
      rsync -av /opt/ecs-templates/ /opt/ecs-templates-os/ && \
      find /opt/ecs-templates-os -name "*.json" -exec sed -i 's/\("type"[[:space:]]*:[[:space:]]*\)"match_only_text"/\1"text"/' "{}" \; && \
      find /opt/ecs-templates-os -name "*.json" -exec sed -i 's/\("type"[[:space:]]*:[[:space:]]*\)"constant_keyword"/\1"keyword"/' "{}" \; && \
      find /opt/ecs-templates-os -name "*.json" -exec sed -i 's/\("type"[[:space:]]*:[[:space:]]*\)"wildcard"/\1"keyword"/' "{}" \; && \
      find /opt/ecs-templates-os -name "*.json" -exec sed -i 's/\("type"[[:space:]]*:[[:space:]]*\)"flattened"/\1"nested"/' "{}" \; && \
      find /opt/ecs-templates-os -name "*.json" -exec sed -i 's/\("type"[[:space:]]*:[[:space:]]*\)"number"/\1"long"/' "{}" \; && \
      rm -rf /opt/ecs && \
    chown -R ${PUSER}:${PGROUP} /data/init \
                                /opt/alerting \
                                /opt/anomaly_detectors \
                                /opt/dashboards \
                                /opt/ecs-templates \
                                /opt/ecs-templates-os \
                                /opt/maps \
                                /opt/notifications \
                                /opt/templates && \
    chmod 755 /data/*.sh /data/*.py /data/init && \
    chmod 400 /opt/maps/* && \
    (echo "*/2 * * * * /data/shared-object-creation.sh\n0 10 * * * /data/index-refresh.py --index MALCOLM_NETWORK_INDEX_PATTERN --template malcolm_template --unassigned\n30 */2 * * * /data/index-refresh.py --index MALCOLM_OTHER_INDEX_PATTERN --template malcolm_beats_template --unassigned\n*/20 * * * * /data/opensearch_index_size_prune.py" > ${SUPERCRONIC_CRONTAB})

EXPOSE $OFFLINE_REGION_MAPS_PORT

ENTRYPOINT ["/usr/bin/tini", \
            "--", \
            "/usr/local/bin/docker-uid-gid-setup.sh", \
            "/usr/local/bin/service_check_passthrough.sh", \
            "-s", "dashboards-helper"]

CMD ["/usr/local/bin/supervisord", "-c", "/etc/supervisord.conf", "-n"]

VOLUME ["/data/init"]

# to be populated at build-time:
ARG BUILD_DATE
ARG MALCOLM_VERSION
ARG VCS_REVISION
ENV BUILD_DATE $BUILD_DATE
ENV MALCOLM_VERSION $MALCOLM_VERSION
ENV VCS_REVISION $VCS_REVISION

LABEL org.opencontainers.image.created=$BUILD_DATE
LABEL org.opencontainers.image.version=$MALCOLM_VERSION
LABEL org.opencontainers.image.revision=$VCS_REVISION
