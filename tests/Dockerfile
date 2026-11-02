# syntax=docker/dockerfile:1
FROM ubuntu:24.04
RUN --mount=type=secret,id=proxy_ca \
    if [ -f /run/secrets/proxy_ca ]; then \
      apt-get -o Acquire::https::CaInfo=/run/secrets/proxy_ca update; \
    else apt-get update; fi && \
    DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
      bash ca-certificates curl gzip passwd python3 shellcheck systemd util-linux && \
    rm -rf /var/lib/apt/lists/*
WORKDIR /app
COPY NodeExporter-auto-install.sh ./
COPY tests/ ./tests/
RUN chmod 0755 /app/NodeExporter-auto-install.sh /app/tests/mock-curl.py /app/tests/mock-systemctl.py && \
    bash -n NodeExporter-auto-install.sh && \
    shellcheck NodeExporter-auto-install.sh tests/run.sh && \
    mkdir -p /test-bin && \
    ln -s /app/tests/mock-curl.py /test-bin/curl && \
    ln -s /app/tests/mock-systemctl.py /test-bin/systemctl
ENV PATH="/test-bin:${PATH}"
CMD ["python3", "-m", "unittest", "discover", "-s", "tests", "-v"]
