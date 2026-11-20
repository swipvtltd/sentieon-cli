FROM debian:13.7-slim AS downloader

ARG TARGETARCH

# Tool versions and pinned SHA-256 checksums. Bumping a version is a
# two-line edit (version + hash) in this block.
ARG SENTIEON_VERSION
ARG SAMTOOLS_VERSION=1.23.1
ARG SAMTOOLS_SHA256=32266198a4bc6a6df395d8526688c9697d9c8e472f888c749fdde2e08ea88dd2
ARG BCFTOOLS_VERSION=1.23.1
ARG BCFTOOLS_SHA256=01899a46f9420cdc1385d52fcfc84cce2806f9c996b787081a90d7dfc85eafa3
ARG BEDTOOLS_VERSION=2.30.0
ARG BEDTOOLS_SHA256=e85d74b6c11b664c05176b1dbf7d2891ad0383ae93805db2d29034db5c2d80ce
ARG ISA_L_VERSION=2.30.0
ARG ISA_L_SHA256=bcf592c04fdfa19e723d2adf53d3e0f4efd5b956bb618fed54a1108d76a6eb56
ARG MOSDEPTH_VERSION=0.3.9
ARG MOSDEPTH_SHA256=ad94aa2bd199c6fd103821d00566765d611f2a4741ce44c5ab723d3b800b911b
ARG VG_VERSION=1.73.0
ARG VG_SHA256=d5752977237e801d971f0d044f43fde4f3005da35f0451b4f452d1c1c9b8414b
# Sentieon's KMC fork adds the `-fa /dev/stdin` patch used by the pangenome pipeline.
ARG KMC_VERSION=3.2.4
ARG KMC_RELEASE_TAG=v3.2.4-pipe3
ARG KMC_SHA256=6ae37ac28c215919a67bd77edf004f9e323013bba5700bc44ad23c0b59da9a91
ARG EXPANSIONHUNTER_VERSION=5.0.0
ARG EXPANSIONHUNTER_SHA256=ebf3ec0ace6e6e3bbce12c26463da5d9f8e16374eff1ad10f0f1a9123050fa86
# T1K and segdup-caller are built from git; pin the tag and verify the
# resolved commit SHA after checkout.
ARG T1K_VERSION=1.0.9
ARG T1K_GIT_TAG=v1.0.9
ARG T1K_COMMIT=9376b555c1d8d2f8ca357c2656f49f450462dbc3
ARG SEGDUP_CALLER_VERSION=0.9.0
ARG SEGDUP_CALLER_GIT_TAG=v0.9.0
ARG SEGDUP_CALLER_COMMIT=37c299fe16970215712b7a4ebdf1932f923e903a
# Pinned Poetry toolchain; should match the version used to generate poetry.lock.
ARG POETRY_VERSION=2.3.4
ARG POETRY_PLUGIN_EXPORT_VERSION=1.9.0

RUN test -n "$SENTIEON_VERSION"

# Install all build dependencies for the downloader stage in one pass.
# nasm is x86-only; cmake is needed to compile ExpansionHunter on arm64; unzip is needed for AWS CLI.
RUN apt-get update && apt-get install -y --no-install-recommends \
      curl ca-certificates bzip2 unzip autoconf automake libtool make cmake gcc g++ perl \
      git python3 python3-venv zlib1g-dev libbz2-dev liblzma-dev \
      libcurl4-gnutls-dev libssl-dev libncurses5-dev libdeflate-dev \
      libperl-dev libgsl0-dev libboost-all-dev && \
    if [ "$TARGETARCH" = "amd64" ]; then \
      apt-get install -y --no-install-recommends nasm; \
    fi && \
    rm -rf /var/lib/apt/lists/*

# Install samtools (compiles natively on both amd64 and arm64)
RUN mkdir -p /opt/samtools/ && \
    curl -fL -o /tmp/samtools.tar.bz2 "https://github.com/samtools/samtools/releases/download/${SAMTOOLS_VERSION}/samtools-${SAMTOOLS_VERSION}.tar.bz2" && \
    echo "${SAMTOOLS_SHA256}  /tmp/samtools.tar.bz2" | sha256sum -c - && \
    tar -C /opt/samtools/ -jxf /tmp/samtools.tar.bz2 && \
    rm /tmp/samtools.tar.bz2 && \
    cd /opt/samtools/samtools-${SAMTOOLS_VERSION} && \
    ./configure && \
    make -j"$(nproc)" install && \
    strip /usr/local/bin/samtools

# Install bcftools (compiles natively on both amd64 and arm64)
RUN mkdir -p /opt/bcftools/ && \
    curl -fL -o /tmp/bcftools.tar.bz2 "https://github.com/samtools/bcftools/releases/download/${BCFTOOLS_VERSION}/bcftools-${BCFTOOLS_VERSION}.tar.bz2" && \
    echo "${BCFTOOLS_SHA256}  /tmp/bcftools.tar.bz2" | sha256sum -c - && \
    tar -C /opt/bcftools/ -jxf /tmp/bcftools.tar.bz2 && \
    rm /tmp/bcftools.tar.bz2 && \
    cd /opt/bcftools/bcftools-${BCFTOOLS_VERSION}/ && \
    ./configure && \
    make -j"$(nproc)" install && \
    strip /usr/local/bin/bcftools

# Install bedtools (static binary on amd64; source build on arm64)
RUN if [ "$TARGETARCH" = "amd64" ]; then \
      curl -fL -o /usr/local/bin/bedtools-${BEDTOOLS_VERSION} \
        "https://github.com/arq5x/bedtools2/releases/download/v${BEDTOOLS_VERSION}/bedtools.static.binary" && \
      echo "${BEDTOOLS_SHA256}  /usr/local/bin/bedtools-${BEDTOOLS_VERSION}" | sha256sum -c - && \
      chmod +x /usr/local/bin/bedtools-${BEDTOOLS_VERSION}; \
    else \
      mkdir -p /tmp/bedtools && \
      curl -fL "https://github.com/arq5x/bedtools2/releases/download/v${BEDTOOLS_VERSION}/bedtools-${BEDTOOLS_VERSION}.tar.gz" | \
        tar -zxf - -C /tmp/bedtools --strip-components=1 && \
      make -C /tmp/bedtools -j"$(nproc)" && \
      cp /tmp/bedtools/bin/bedtools /usr/local/bin/bedtools-${BEDTOOLS_VERSION} && \
      strip /usr/local/bin/bedtools-${BEDTOOLS_VERSION} && \
      rm -rf /tmp/bedtools; \
    fi

# Install igzip (isa-l)
RUN mkdir -p /opt/isa-l && \
    curl -fL -o /tmp/isa-l.tar.gz "https://github.com/intel/isa-l/archive/refs/tags/v${ISA_L_VERSION}.tar.gz" && \
    echo "${ISA_L_SHA256}  /tmp/isa-l.tar.gz" | sha256sum -c - && \
    tar -C /opt/isa-l -zxf /tmp/isa-l.tar.gz && \
    rm /tmp/isa-l.tar.gz && \
    cd /opt/isa-l/isa-l-${ISA_L_VERSION} && \
    ./autogen.sh && \
    ./configure --prefix=/usr --libdir=/usr/lib && \
    make -j"$(nproc)" install

# Install mosdepth (static binary on amd64; bioconda arm64 binary via micromamba on arm64)
RUN if [ "$TARGETARCH" = "amd64" ]; then \
      curl -fL -o /usr/local/bin/mosdepth-${MOSDEPTH_VERSION} \
        "https://github.com/brentp/mosdepth/releases/download/v${MOSDEPTH_VERSION}/mosdepth" && \
      echo "${MOSDEPTH_SHA256}  /usr/local/bin/mosdepth-${MOSDEPTH_VERSION}" | sha256sum -c - && \
      chmod +x /usr/local/bin/mosdepth-${MOSDEPTH_VERSION}; \
    else \
      curl -Ls https://micro.mamba.pm/api/micromamba/linux-aarch64/latest | tar -xvj -C /tmp bin/micromamba && \
      /tmp/bin/micromamba create -y -p /tmp/mosdepth-env -c bioconda -c conda-forge "mosdepth=${MOSDEPTH_VERSION}" && \
      cp /tmp/mosdepth-env/bin/mosdepth /usr/local/bin/mosdepth-${MOSDEPTH_VERSION} && \
      rm -rf /tmp/bin /tmp/mosdepth-env; \
    fi

# Install vg (amd64 only; no official arm64 static binary exists)
RUN mkdir -p /opt/vg-bin && \
    if [ "$TARGETARCH" = "amd64" ]; then \
      curl -fL -o /opt/vg-bin/vg-${VG_VERSION} \
        "https://github.com/vgteam/vg/releases/download/v${VG_VERSION}/vg" && \
      echo "${VG_SHA256}  /opt/vg-bin/vg-${VG_VERSION}" | sha256sum -c - && \
      chmod +x /opt/vg-bin/vg-${VG_VERSION}; \
    fi

# Install kmc (prebuilt on amd64; source build from Sentieon fork on arm64)
RUN mkdir -p /opt/kmc-${KMC_VERSION} && \
    if [ "$TARGETARCH" = "amd64" ]; then \
      curl -fL -o /tmp/kmc.tar.gz "https://github.com/Sentieon/KMC/releases/download/${KMC_RELEASE_TAG}/KMC${KMC_VERSION}.linux.x64.tar.gz" && \
      echo "${KMC_SHA256}  /tmp/kmc.tar.gz" | sha256sum -c - && \
      tar -C /opt/kmc-${KMC_VERSION} -zxf /tmp/kmc.tar.gz && \
      rm /tmp/kmc.tar.gz && \
      cp /opt/kmc-${KMC_VERSION}/bin/kmc /usr/local/bin/kmc-${KMC_VERSION} && \
      cp /opt/kmc-${KMC_VERSION}/bin/kmc_tools /usr/local/bin/kmc_tools-${KMC_VERSION} && \
      cp /opt/kmc-${KMC_VERSION}/bin/kmc_dump /usr/local/bin/kmc_dump-${KMC_VERSION}; \
    else \
      git clone --depth 1 --branch "${KMC_RELEASE_TAG}" https://github.com/Sentieon/KMC.git /tmp/kmc-src && \
      make -C /tmp/kmc-src -j"$(nproc)" && \
      cp /tmp/kmc-src/bin/kmc /usr/local/bin/kmc-${KMC_VERSION} && \
      cp /tmp/kmc-src/bin/kmc_tools /usr/local/bin/kmc_tools-${KMC_VERSION} && \
      cp /tmp/kmc-src/bin/kmc_dump /usr/local/bin/kmc_dump-${KMC_VERSION} && \
      rm -rf /tmp/kmc-src; \
    fi && \
    chmod +x /usr/local/bin/kmc-${KMC_VERSION} \
      /usr/local/bin/kmc_tools-${KMC_VERSION} \
      /usr/local/bin/kmc_dump-${KMC_VERSION}

# Install ExpansionHunter (prebuilt on amd64; CMake source build on arm64)
RUN mkdir -p /tmp/eh && \
    if [ "$TARGETARCH" = "amd64" ]; then \
      curl -fL -o /tmp/eh.tar.gz "https://github.com/Illumina/ExpansionHunter/releases/download/v${EXPANSIONHUNTER_VERSION}/ExpansionHunter-v${EXPANSIONHUNTER_VERSION}-linux_x86_64.tar.gz" && \
      echo "${EXPANSIONHUNTER_SHA256}  /tmp/eh.tar.gz" | sha256sum -c - && \
      tar -C /tmp/eh --strip-components=1 -zxf /tmp/eh.tar.gz && \
      cp /tmp/eh/bin/ExpansionHunter /usr/local/bin/ExpansionHunter-${EXPANSIONHUNTER_VERSION}; \
    else \
      curl -fL "https://github.com/Illumina/ExpansionHunter/archive/refs/tags/v${EXPANSIONHUNTER_VERSION}.tar.gz" | \
        tar -C /tmp/eh --strip-components=1 -zxf - && \
      cmake -S /tmp/eh -B /tmp/eh/build -DCMAKE_BUILD_TYPE=Release && \
      cmake --build /tmp/eh/build -j"$(nproc)" && \
      cp /tmp/eh/build/install/bin/ExpansionHunter /usr/local/bin/ExpansionHunter-${EXPANSIONHUNTER_VERSION}; \
    fi && \
    chmod +x /usr/local/bin/ExpansionHunter-${EXPANSIONHUNTER_VERSION} && \
    rm -rf /tmp/eh /tmp/eh.tar.gz

# Build T1K from source
RUN git clone --branch ${T1K_GIT_TAG} https://github.com/mourisl/T1K.git /tmp/t1k-src && \
    cd /tmp/t1k-src && \
    test "$(git rev-parse HEAD)" = "${T1K_COMMIT}" && \
    make -j"$(nproc)" && \
    mkdir -p /opt/t1k-${T1K_VERSION} && \
    cp run-t1k bam-extractor fastq-extractor genotyper analyzer \
       /opt/t1k-${T1K_VERSION}/ && \
    rm -rf /tmp/t1k-src

# Install AWS CLI v2
RUN ARCH=$(uname -m) && \
    if [ "$ARCH" = "x86_64" ]; then \
        AWS_URL="https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip"; \
    elif [ "$ARCH" = "aarch64" ]; then \
        AWS_URL="https://awscli.amazonaws.com/awscli-exe-linux-aarch64.zip"; \
    else \
        echo "Unsupported architecture: $ARCH" && exit 1; \
    fi && \
    curl -sL "$AWS_URL" -o "awscliv2.zip" && \
    unzip -q awscliv2.zip && \
    ./aws/install && \
    rm -rf aws awscliv2.zip

# Clone segdup-caller
RUN git clone --branch ${SEGDUP_CALLER_GIT_TAG} https://github.com/Sentieon/segdup-caller.git /opt/segdup-caller-src && \
    cd /opt/segdup-caller-src && \
    test "$(git rev-parse HEAD)" = "${SEGDUP_CALLER_COMMIT}"

# Download the Sentieon software and normalize the destination directory name
RUN mkdir -p /opt/sentieon/sentieon-genomics-${SENTIEON_VERSION} && \
    if [ "$TARGETARCH" = "amd64" ]; then \
      SENTIEON_URL="https://s3.amazonaws.com/sentieon-release/software/sentieon-genomics-${SENTIEON_VERSION}.tar.gz"; \
    elif [ "$TARGETARCH" = "arm64" ]; then \
      SENTIEON_URL="https://s3.amazonaws.com/sentieon-release/software/arm-sentieon-genomics-${SENTIEON_VERSION}.tar.gz"; \
    else \
      echo "Unsupported TARGETARCH: $TARGETARCH" && exit 1; \
    fi && \
    curl -fL "$SENTIEON_URL" | \
      tar -zxf - --strip-components=1 -C /opt/sentieon/sentieon-genomics-${SENTIEON_VERSION}

# Install poetry
RUN python3 -m venv /opt/poetry-venv && \
    /opt/poetry-venv/bin/pip install --no-cache-dir "poetry==${POETRY_VERSION}"

# Build the sentieon-cli wheel and requirements.txt
COPY data /opt/sentieon-cli/data
COPY pyproject.toml /opt/sentieon-cli/pyproject.toml
COPY poetry.lock /opt/sentieon-cli/poetry.lock
COPY sentieon_cli /opt/sentieon-cli/sentieon_cli
COPY README.md /opt/sentieon-cli/README.md
RUN /opt/poetry-venv/bin/pip install --no-cache-dir \
      "poetry-plugin-export==${POETRY_PLUGIN_EXPORT_VERSION}" && \
    cd /opt/sentieon-cli/ && \
    /opt/poetry-venv/bin/poetry build -f wheel && \
    /opt/poetry-venv/bin/poetry export \
      --only main,container \
      --format requirements.txt \
      -o /opt/sentieon-cli/dist/requirements.txt

# -----------------------------------------------------------------------------
# Build the Python environments in an isolated stage
# -----------------------------------------------------------------------------
FROM debian:13.7-slim AS python-builder
ARG SENTIEON_VERSION

COPY --from=downloader /opt/sentieon-cli/dist /opt/sentieon-cli/dist
COPY --from=downloader /opt/segdup-caller-src /opt/segdup-caller-src

RUN apt-get update && \
    apt-get install -y --no-install-recommends \
      python3 python3-venv python3-dev \
      gcc g++ make zlib1g-dev libbz2-dev liblzma-dev libcurl4-gnutls-dev && \
    rm -rf /var/lib/apt/lists/* && \
    python3 -m venv /opt/sentieon-cli-venv && \
    /opt/sentieon-cli-venv/bin/pip install --no-cache-dir \
      -r /opt/sentieon-cli/dist/requirements.txt && \
    /opt/sentieon-cli-venv/bin/pip install --no-cache-dir --no-deps \
      /opt/sentieon-cli/dist/*.whl && \
    /opt/sentieon-cli-venv/bin/pip uninstall -y kaleido pyarrow && \
    /opt/sentieon-cli-venv/bin/pip uninstall -y pip setuptools wheel && \
    python3 -m venv /opt/segdup-caller-venv && \
    /opt/segdup-caller-venv/bin/pip install --no-cache-dir \
      /opt/segdup-caller-src && \
    /opt/segdup-caller-venv/bin/pip uninstall -y pip setuptools wheel && \
    find /opt/sentieon-cli-venv /opt/segdup-caller-venv \
      -depth -type d -name __pycache__ -exec rm -rf {} +

# -----------------------------------------------------------------------------
# Final runtime container
# -----------------------------------------------------------------------------
FROM debian:13.7-slim

ARG TARGETARCH
ARG SENTIEON_VERSION
ARG BEDTOOLS_VERSION=2.30.0
ARG MOSDEPTH_VERSION=0.3.9
ARG VG_VERSION=1.73.0
ARG KMC_VERSION=3.2.4
ARG EXPANSIONHUNTER_VERSION=5.0.0
ARG T1K_VERSION=1.0.9
ARG VCS_REF
ARG BUILD_DATE

ENV SENTIEON_VERSION=$SENTIEON_VERSION

LABEL org.opencontainers.image.title="sentieon-cli" \
      org.opencontainers.image.description="Pipeline implementations for the Sentieon software" \
      org.opencontainers.image.vendor="Sentieon" \
      org.opencontainers.image.url="https://www.sentieon.com/" \
      org.opencontainers.image.source="https://github.com/Sentieon/sentieon-cli" \
      org.opencontainers.image.licenses="BSD-2-Clause" \
      org.opencontainers.image.base.name="debian:13.7-slim" \
      org.opencontainers.image.version="${SENTIEON_VERSION}" \
      org.opencontainers.image.revision="${VCS_REF}" \
      org.opencontainers.image.created="${BUILD_DATE}"

COPY --from=downloader /opt/sentieon/sentieon-genomics-${SENTIEON_VERSION} /opt/sentieon/sentieon-genomics-${SENTIEON_VERSION}
COPY --from=downloader /usr/bin/igzip /usr/bin/igzip
COPY --from=downloader /usr/lib/libisal.so.2.0.30 /usr/lib/libisal.so.2.0.30
COPY --from=downloader /usr/local/bin/samtools /usr/local/bin/samtools
COPY --from=downloader /usr/local/bin/bcftools /usr/local/bin/bcftools
COPY --from=downloader /usr/local/bin/bedtools-${BEDTOOLS_VERSION} /usr/local/bin/bedtools-${BEDTOOLS_VERSION}
COPY --from=downloader /usr/local/bin/mosdepth-${MOSDEPTH_VERSION} /usr/local/bin/mosdepth-${MOSDEPTH_VERSION}
COPY --from=downloader /opt/vg-bin/ /usr/local/bin/
COPY --from=downloader /usr/local/bin/kmc-${KMC_VERSION} /usr/local/bin/kmc-${KMC_VERSION}
COPY --from=downloader /usr/local/bin/kmc_tools-${KMC_VERSION} /usr/local/bin/kmc_tools-${KMC_VERSION}
COPY --from=downloader /usr/local/bin/kmc_dump-${KMC_VERSION} /usr/local/bin/kmc_dump-${KMC_VERSION}
COPY --from=downloader /usr/local/bin/ExpansionHunter-${EXPANSIONHUNTER_VERSION} /usr/local/bin/ExpansionHunter-${EXPANSIONHUNTER_VERSION}
COPY --from=downloader /opt/t1k-${T1K_VERSION} /opt/t1k-${T1K_VERSION}
COPY --from=downloader /opt/sentieon-cli/dist /opt/sentieon-cli/dist
COPY --from=downloader /usr/local/aws-cli /usr/local/aws-cli

# Create symlinks for libisal, AWS CLI, and third-party tools
RUN cd /usr/lib && \
    ln -s libisal.so.2.0.30 libisal.so.2 && \
    ln -s libisal.so.2 libisal.so && \
    cd /usr/local/bin/ && \
    ln -s /usr/local/aws-cli/v2/current/bin/aws aws && \
    ln -s bedtools-${BEDTOOLS_VERSION} bedtools && \
    ln -s mosdepth-${MOSDEPTH_VERSION} mosdepth && \
    if [ -f "vg-${VG_VERSION}" ]; then ln -s vg-${VG_VERSION} vg; fi && \
    ln -s kmc-${KMC_VERSION} kmc && \
    ln -s kmc_tools-${KMC_VERSION} kmc_tools && \
    ln -s kmc_dump-${KMC_VERSION} kmc_dump && \
    ln -s /opt/t1k-${T1K_VERSION}/run-t1k run-t1k && \
    printf '#!/bin/sh\nexec env -u LD_PRELOAD /usr/local/bin/ExpansionHunter-%s "$@"\n' \
        "${EXPANSIONHUNTER_VERSION}" > ExpansionHunter && \
    chmod +x ExpansionHunter

# Install runtime dependencies and create an arch-agnostic symlink for libjemalloc
RUN apt-get update && \
    apt-get install -y --no-install-recommends \
      libjemalloc2 procps libdeflate0 libbz2-1.0 liblzma5 \
      libcurl3-gnutls libssl3 libperl5.40 libgsl28 libncurses6 \
      libstdc++6 perl curl python3 && \
    rm -rf /var/lib/apt/lists/* && \
    find /usr/lib -name libjemalloc.so.2 -exec ln -sf {} /usr/lib/libjemalloc.so.2 \;

ENV SENTIEON_INSTALL_DIR=/opt/sentieon/sentieon-genomics-$SENTIEON_VERSION
ENV PATH=$SENTIEON_INSTALL_DIR/bin/:$PATH
ENV LD_PRELOAD=/usr/lib/libjemalloc.so.2

# Default jemalloc configuration
ENV MALLOC_CONF=metadata_thp:auto,background_thread:true,dirty_decay_ms:30000,muzzy_decay_ms:30000

# Copy the pre-built venvs from the python-builder stage
COPY --from=python-builder /opt/sentieon-cli-venv /opt/sentieon-cli-venv
COPY --from=python-builder /opt/segdup-caller-venv /opt/segdup-caller-venv
ENV VIRTUAL_ENV=/opt/sentieon-cli-venv
ENV PATH=/opt/sentieon-cli-venv/bin:$PATH
ENV PATH=$PATH:/opt/segdup-caller-venv/bin

# Create a non-root user for running the pipelines
RUN useradd --create-home --uid 1001 --shell /bin/bash sentieon
USER sentieon
WORKDIR /home/sentieon

# Test the container
RUN sentieon driver --help && \
    igzip --help && \
    samtools --help && \
    bcftools --help && \
    bedtools --help && \
    multiqc -h && \
    mosdepth -h && \
    if [ "$TARGETARCH" = "amd64" ]; then vg version; fi && \
    kmc --help && \
    ExpansionHunter --help && \
    perl -c "$(command -v run-t1k)" && \
    aws --version && \
    SENTIEON_LICENSE=placeholder segdup-caller --version && \
    SENTIEON_LICENSE=placeholder python -c "import sys; from packaging.version import Version; \
from sentieon_cli.stages.segdup import SEGDUP_MIN_VERSIONS; \
from sentieon_cli.util import check_version; \
sys.exit(0 if all(check_version(c, v) for c, v in SEGDUP_MIN_VERSIONS.items()) else 1)" && \
    sentieon-cli -h
