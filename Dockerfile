FROM ubuntu:24.04

ARG NIM_VERSION=2.2.12
ENV DEBIAN_FRONTEND=noninteractive \
    NIM_ROOT=/opt/nim \
    PATH="/opt/nim/bin:${PATH}"

RUN apt-get update && apt-get install -y --no-install-recommends \
    ca-certificates \
    curl \
    xz-utils \
    gcc \
    libc6-dev \
    binutils \
  && rm -rf /var/lib/apt/lists/*

RUN curl -fsSL "https://nim-lang.org/download/nim-${NIM_VERSION}-linux_x64.tar.xz" -o /tmp/nim.tar.xz \
  && mkdir -p /opt \
  && tar -xJf /tmp/nim.tar.xz -C /opt \
  && mv "/opt/nim-${NIM_VERSION}" /opt/nim \
  && rm -f /tmp/nim.tar.xz \
  && ln -sf /opt/nim/bin/nim /usr/local/bin/nim \
  && ln -sf /opt/nim/bin/nimble /usr/local/bin/nimble

WORKDIR /opt/nimrt
COPY nim.cfg nim_ecosystem.nimble LICENSE README.md ./
COPY src ./src
COPY compiler ./compiler

RUN nim c --skipParentCfg:on -d:release -o:/opt/nim/bin/nim_safe compiler/nim_safe.nim \
  && strip /opt/nim/bin/nim_safe \
  && ln -sf /opt/nim/bin/nim_safe /usr/local/bin/nim_safe \
  && rm -rf /root/.cache/nim /opt/nimrt/nimcache

RUN nim_safe --version \
  && nim check --path:/opt/nimrt/src /opt/nimrt/src/corex.nim \
  && nim check --path:/opt/nimrt/src /opt/nimrt/src/algx.nim

LABEL org.opencontainers.image.title="NimRT nim_safe Compiler" \
      org.opencontainers.image.description="Experimental memory-safe Nim compiler wrapper (--mem-safe, --safe-mode, --check-safe-atf) with CoreX and AlgX headers" \
      org.opencontainers.image.source="https://github.com/stylizedapp/nimrt" \
      org.opencontainers.image.licenses="MIT" \
      org.opencontainers.image.version="04.03.03"

WORKDIR /workspace
ENTRYPOINT ["nim_safe"]
CMD ["--help"]
