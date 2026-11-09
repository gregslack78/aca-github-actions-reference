FROM ubuntu:24.04
ARG RUNNER_VERSION
ARG RUNNER_SHA256
ENV DEBIAN_FRONTEND=noninteractive \
    AZURE_EXTENSION_DIR=/opt/azure-cli-extensions
RUN apt-get update && apt-get install -y --no-install-recommends \
    ca-certificates curl git jq python3 openssl tar gzip gnupg \
    && mkdir -p /etc/apt/keyrings \
    && curl -fsSL https://packages.microsoft.com/keys/microsoft.asc \
       | gpg --dearmor -o /etc/apt/keyrings/microsoft.gpg \
    && echo "deb [arch=amd64 signed-by=/etc/apt/keyrings/microsoft.gpg] https://packages.microsoft.com/repos/azure-cli/ noble main" \
       > /etc/apt/sources.list.d/azure-cli.list \
    && apt-get update && apt-get install -y --no-install-recommends azure-cli \
    && rm -rf /var/lib/apt/lists/*
WORKDIR /opt/runner
RUN test -n "$RUNNER_VERSION" && test -n "$RUNNER_SHA256" \
    && curl -fsSL -o /tmp/runner.tar.gz \
       "https://github.com/actions/runner/releases/download/v${RUNNER_VERSION}/actions-runner-linux-x64-${RUNNER_VERSION}.tar.gz" \
    && echo "${RUNNER_SHA256}  /tmp/runner.tar.gz" | sha256sum --check \
    && tar -xzf /tmp/runner.tar.gz -C /opt/runner \
    && rm /tmp/runner.tar.gz \
    && ./bin/installdependencies.sh \
    && az extension add --name containerapp --upgrade --only-show-errors \
    && chmod -R a+rX /opt/azure-cli-extensions \
    && useradd --uid 10001 --create-home --shell /bin/bash runner \
    && chown -R runner:runner /opt/runner
COPY --chown=runner:runner runner/entrypoint.sh /opt/runner/entrypoint.sh
USER runner
ENV HOME=/home/runner
ENTRYPOINT ["/bin/bash", "/opt/runner/entrypoint.sh"]
