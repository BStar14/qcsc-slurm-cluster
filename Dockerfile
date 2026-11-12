# syntax=docker/dockerfile:1.7
#
# qcsc-slurm-cluster: a small Slurm cluster image (login, slurmctld, slurmdbd, compute)
# with OpenMPI/PMIx, the QRMI SPANK plugin, sshd, and a user toolchain.
#
# Targets:
#   cluster  the cluster only: no uv, no Python virtual environment, no qcsc-prefect
#   qcsc     (default) cluster, plus qcsc-prefect preinstalled for the qcsc user, as after
#            Steps 2, 4, 5 and 8 of the setup guide and the tutorial's install steps
#            (install/setup-qcsc-user.sh), and JupyterLab in /opt/jupyter
# Both carry the user files of this repository (compose.yml, Makefile, .devcontainer),
# which `docker run --rm <image> bundle | tar -x` extracts, so users need only the image.
#
# Adapted from giovtorres/slurm-docker-cluster (MIT) and the SPANK plugin demo of
# qiskit-community/spank-plugins. See NOTICE.

ARG ROCKY_VERSION=9
ARG PMIX_VERSION=4.1.3
ARG SLURM_TAG=slurm-25-11-6-1
ARG OPENMPI_VERSION=4.1.8
ARG SPANK_REPO=https://github.com/qiskit-community/spank-plugins.git
ARG SPANK_REF=c3d5679e688ad77146a15335fc2ab466429a2895
ARG QRMI_REPO=https://github.com/qiskit-community/qrmi.git
ARG QRMI_REF=3deb5124c448b73f1a44c083d18517c42df7e23a
ARG GOSU_VERSION=1.17
# The qcsc target. QRMI_PIP_VERSION is the release that QRMI_REF builds on (0.26.3-2).
# QCSC_PREFECT_SHA pins the commit of QCSC_PREFECT_REF and keys the build cache: the
# Makefile and the publish workflow set it from `git ls-remote`, so a new commit on main
# rebuilds the qcsc layer instead of reusing an old clone.
ARG UV_VERSION=0.11.6
ARG QCSC_PREFECT_REPO=https://github.com/qiskit-community/qcsc-prefect.git
ARG QCSC_PREFECT_REF=main
ARG QCSC_PREFECT_SHA=
ARG QRMI_PIP_VERSION=0.26.3
ARG FFSIM_VERSION=0.0.86
ARG JUPYTERLAB_VERSION=4.6.6
# The image that the bundled compose.yml and .env.example run by default: the tag of this
# build (the Makefile and the publish workflow set it), so the bundle matches its image.
ARG QCSC_CLUSTER_IMAGE=quay.io/boseong14/qcsc-slurm-cluster:latest

# ------------------------------------------------------------------ build base
FROM rockylinux:${ROCKY_VERSION} AS build-base
RUN dnf -y install dnf-plugins-core \
    && dnf config-manager --set-enabled crb \
    && dnf -y install gcc gcc-c++ make git wget bzip2 perl autoconf automake libtool flex \
        cmake munge-devel mariadb-devel http-parser-devel json-c-devel libyaml-devel \
        lua-devel libevent-devel hwloc-devel openssl-devel pam-devel readline-devel \
    && dnf clean all

# ------------------------------------------------------------------ PMIx
FROM build-base AS pmix
ARG PMIX_VERSION
RUN wget -nv https://github.com/openpmix/openpmix/releases/download/v${PMIX_VERSION}/pmix-${PMIX_VERSION}.tar.gz \
    && tar -xf pmix-${PMIX_VERSION}.tar.gz \
    && cd pmix-${PMIX_VERSION} \
    && ./configure --prefix=/opt/pmix \
    && make -j"$(nproc)" install

# ------------------------------------------------------------------ Slurm
FROM pmix AS slurm
ARG SLURM_TAG
RUN git clone -b ${SLURM_TAG} --single-branch --depth=1 https://github.com/SchedMD/slurm.git /src/slurm \
    && cd /src/slurm \
    && ./configure --prefix=/usr --sysconfdir=/etc/slurm --libdir=/usr/lib64 \
        --with-mysql_config=/usr/bin --with-pmix=/opt/pmix \
    && make -j"$(nproc)" \
    && make install DESTDIR=/out \
    && install -D -m644 contribs/slurm_completion_help/slurm_completion.sh \
        /out/etc/profile.d/slurm_completion.sh

# ------------------------------------------------------------------ OpenMPI
# Not FROM pmix: that stage's ARG PMIX_VERSION would reach configure as an environment
# variable, and OpenMPI's configure stops on the clash with its own PMIX_VERSION.
FROM build-base AS openmpi
ARG OPENMPI_VERSION
COPY --from=pmix /opt/pmix /opt/pmix
COPY --from=slurm /out/ /
RUN wget -nv https://download.open-mpi.org/release/open-mpi/v${OPENMPI_VERSION%.*}/openmpi-${OPENMPI_VERSION}.tar.gz \
    && tar -xf openmpi-${OPENMPI_VERSION}.tar.gz \
    && cd openmpi-${OPENMPI_VERSION} \
    && ./configure --prefix=/opt/openmpi --with-slurm --with-pmix=/opt/pmix \
    && make -j"$(nproc)" \
    && make install

# ------------------------------------------------------------------ SPANK QRMI plugin
FROM build-base AS spank-qrmi
ARG SPANK_REPO
ARG SPANK_REF
ARG QRMI_REPO
ARG QRMI_REF
COPY --from=slurm /out/usr/include/slurm /usr/include/slurm
RUN curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y --profile minimal
RUN git init -q /src/spank-plugins && cd /src/spank-plugins \
    && git fetch -q --depth=1 ${SPANK_REPO} ${SPANK_REF} && git checkout -q FETCH_HEAD \
    && git init -q /src/qrmi && cd /src/qrmi \
    && git fetch -q --depth=1 ${QRMI_REPO} ${QRMI_REF} && git checkout -q FETCH_HEAD
# Keep a copy of the GPL-3.0 plugin source for the runtime image (see NOTICE).
RUN mkdir -p /out/usr/src \
    && git -C /src/spank-plugins archive --format=tar --prefix=spank-plugins/ HEAD \
        | tar -x -C /out/usr/src
RUN source ~/.cargo/env \
    && mkdir /src/spank-plugins/plugins/spank_qrmi/build \
    && cd /src/spank-plugins/plugins/spank_qrmi/build \
    && cmake -DQRMI_ROOT=/src/qrmi .. \
    && make -j"$(nproc)" \
    && install -D -m755 spank_qrmi.so /out/usr/lib64/slurm/spank_qrmi.so

# ------------------------------------------------------------------ ffsim wheel
# The PyPI manylinux aarch64 wheels of ffsim have Arm SVE instructions, which raise
# SIGILL on CPUs without SVE, such as Apple Silicon under Docker. On arm64, build the
# wheel from the sdist for the generic aarch64 target and check it; on amd64, use the
# PyPI wheel.
FROM build-base AS ffsim-wheel
ARG FFSIM_VERSION
ARG TARGETARCH
RUN dnf -y install python3.12 python3.12-devel python3.12-pip binutils && dnf clean all
RUN set -euo pipefail; \
    if [ "$TARGETARCH" = arm64 ]; then \
        curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y --profile minimal; \
        source ~/.cargo/env; \
        python3.12 -m pip wheel --no-deps --no-binary ffsim "ffsim==${FFSIM_VERSION}" -w /wheels; \
        mkdir /tmp/whl && python3.12 -m zipfile -e /wheels/ffsim-*.whl /tmp/whl; \
        for so in /tmp/whl/ffsim/_lib*.so; do \
            if objdump -d --no-show-raw-insn "$so" \
                | grep -qE '\s(index|ptrue|whilelo|whilelt|ld1d|st1d)\s+[zp][0-9]'; then \
                echo "error: $so has SVE instructions" >&2; exit 1; \
            fi; \
        done; \
    else \
        python3.12 -m pip download --no-deps --only-binary :all: "ffsim==${FFSIM_VERSION}" -d /wheels; \
    fi; \
    ls /wheels

# ------------------------------------------------------------------ bundle
# The user files, with the default image set to QCSC_CLUSTER_IMAGE. A stage of its own,
# copied last into each target, so editing these files never rebuilds the qcsc layer.
FROM rockylinux:${ROCKY_VERSION} AS bundle
ARG QCSC_CLUSTER_IMAGE
COPY compose.yml Makefile .env.example README.md LICENSE NOTICE /bundle/
COPY .devcontainer/ /bundle/.devcontainer/
COPY tests/ /bundle/tests/
RUN sed -i "s#quay.io/boseong14/qcsc-slurm-cluster:latest#${QCSC_CLUSTER_IMAGE}#" \
        /bundle/compose.yml /bundle/.env.example \
    && grep -qF "${QCSC_CLUSTER_IMAGE}" /bundle/compose.yml

# ------------------------------------------------------------------ cluster base
FROM rockylinux:${ROCKY_VERSION} AS cluster-base
ARG GOSU_VERSION
ARG SLURM_TAG
ARG PMIX_VERSION
ARG OPENMPI_VERSION
ARG SPANK_REF
ARG QRMI_REF

LABEL org.opencontainers.image.title="qcsc-slurm-cluster" \
      org.opencontainers.image.description="Slurm cluster with OpenMPI/PMIx and the QRMI SPANK plugin, for qcsc-prefect workflows" \
      org.opencontainers.image.source="https://github.com/BStar14/qcsc-slurm-cluster" \
      org.opencontainers.image.licenses="MIT" \
      io.qcsc.slurm="${SLURM_TAG}" \
      io.qcsc.pmix="${PMIX_VERSION}" \
      io.qcsc.openmpi="${OPENMPI_VERSION}" \
      io.qcsc.spank-plugins="${SPANK_REF}" \
      io.qcsc.qrmi="${QRMI_REF}"

# Runtime libraries of Slurm and MPI, the cluster services, and the user toolchain
# that the solver build scripts of qcsc-prefect need (C/C++/Fortran, CMake, git,
# OpenBLAS/LAPACK, pkg-config, Python 3.12 with headers).
RUN dnf -y install dnf-plugins-core epel-release \
    && dnf config-manager --set-enabled crb \
    && dnf -y install \
        munge mariadb-connector-c http-parser json-c libyaml lua-libs libevent hwloc-libs readline \
        openssh-server openssh-clients sudo \
        gcc gcc-c++ gcc-gfortran make cmake git pkgconf-pkg-config \
        openblas-devel lapack-devel \
        python3.12 python3.12-devel python3.12-pip \
        curl-minimal ca-certificates which tar gzip bzip2 xz unzip findutils \
        procps-ng iproute iputils less vim-minimal nano bash-completion \
    && dnf clean all \
    && rm -rf /var/cache/dnf

COPY --from=slurm /out/ /
COPY --from=pmix /opt/pmix /opt/pmix
COPY --from=openmpi /opt/openmpi /opt/openmpi
COPY --from=spank-qrmi /out/ /

RUN set -eux; \
    arch="$(uname -m | sed -e s/x86_64/amd64/ -e s/aarch64/arm64/)"; \
    curl -fsSL -o /usr/local/bin/gosu \
        "https://github.com/tianon/gosu/releases/download/${GOSU_VERSION}/gosu-${arch}"; \
    chmod +x /usr/local/bin/gosu; gosu nobody true

# MPI and Python on every PATH: login shells (profile.d), non-login shells and jobs (ENV).
ENV PATH=/opt/openmpi/bin:${PATH} \
    LD_LIBRARY_PATH=/opt/openmpi/lib:/opt/pmix/lib \
    MANPATH=/opt/openmpi/share/man
RUN printf '%s\n' \
        'export PATH=/opt/openmpi/bin:$PATH' \
        'export LD_LIBRARY_PATH=/opt/openmpi/lib:/opt/pmix/lib${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}' \
        > /etc/profile.d/openmpi.sh \
    && printf '%s\n' /opt/openmpi/lib /opt/pmix/lib > /etc/ld.so.conf.d/qcsc-mpi.conf \
    && ldconfig \
    && alternatives --install /usr/bin/python3 python3 /usr/bin/python3.12 10

# Slurm service account and state directories (uid/gid 990, as upstream).
RUN groupadd -r --gid=990 slurm \
    && useradd -r -g slurm --uid=990 -d /var/lib/slurm -s /sbin/nologin slurm \
    && mkdir -p /var/spool/slurmd /var/run/slurmd /var/run/slurmdbd /var/lib/slurmd \
        /var/log/slurm /etc/slurm \
    && chown -R slurm:slurm /var/spool/slurmd /var/run/slurmd /var/run/slurmdbd \
        /var/lib/slurmd /var/log/slurm

# The login user: uid/gid 1000, key-only SSH, passwordless sudo.
RUN groupadd --gid 1000 qcsc \
    && useradd --uid 1000 --gid 1000 -m -s /bin/bash qcsc \
    && passwd -l qcsc \
    && echo 'qcsc ALL=(ALL) NOPASSWD:ALL' > /etc/sudoers.d/qcsc \
    && chmod 440 /etc/sudoers.d/qcsc \
    && mkdir -p /shared/work \
    && chown qcsc:qcsc /shared /shared/work

# sshd: no passwords, no root login. pam_loginuid fails in containers, so make it optional.
RUN sed -i 's/^session\s\+required\s\+pam_loginuid.so/session optional pam_loginuid.so/' /etc/pam.d/sshd \
    && printf '%s\n' \
        'PasswordAuthentication no' \
        'KbdInteractiveAuthentication no' \
        'PermitRootLogin no' \
        'AllowUsers qcsc' \
        'HostKey /etc/ssh/keys/ssh_host_ed25519_key' \
        'HostKey /etc/ssh/keys/ssh_host_rsa_key' \
        > /etc/ssh/sshd_config.d/10-qcsc.conf \
    && rm -f /etc/ssh/ssh_host_*

# Slurm configuration. The entrypoint copies it into the shared /etc/slurm volume
# on first start, so a running cluster keeps edits and the installed qrmi_config.json.
COPY etc/slurm/ /usr/share/qcsc-cluster/slurm/
COPY docker-entrypoint.sh /usr/local/bin/docker-entrypoint.sh
RUN chmod 755 /usr/local/bin/docker-entrypoint.sh

ENTRYPOINT ["/usr/local/bin/docker-entrypoint.sh"]
CMD ["login"]

# ------------------------------------------------------------------ cluster
FROM cluster-base AS cluster
COPY --from=bundle /bundle/ /usr/share/qcsc-cluster/bundle/

# ------------------------------------------------------------------ qcsc (default)
FROM cluster-base AS qcsc
ARG UV_VERSION
ARG QCSC_PREFECT_REPO
ARG QCSC_PREFECT_REF
ARG QCSC_PREFECT_SHA
ARG QRMI_PIP_VERSION
ARG FFSIM_VERSION
ARG JUPYTERLAB_VERSION

LABEL org.opencontainers.image.description="Slurm cluster with OpenMPI/PMIx, the QRMI SPANK plugin, and qcsc-prefect with the SQD workflow and Fulqrum preinstalled" \
      io.qcsc.qcsc-prefect.ref="${QCSC_PREFECT_REF}" \
      io.qcsc.qcsc-prefect.commit="${QCSC_PREFECT_SHA}" \
      io.qcsc.uv="${UV_VERSION}" \
      io.qcsc.qrmi-pip="${QRMI_PIP_VERSION}" \
      io.qcsc.ffsim="${FFSIM_VERSION}"

# JupyterLab for `make jupyter`, outside the qcsc user's environments.
RUN python3.12 -m venv /opt/jupyter \
    && /opt/jupyter/bin/pip install --no-cache-dir "jupyterlab==${JUPYTERLAB_VERSION}"

COPY --from=ffsim-wheel /wheels /opt/wheels/ffsim
COPY install/setup-qcsc-user.sh /usr/share/qcsc-cluster/setup-qcsc-user.sh

# The cache mounts below must not leave root-owned directories in the home.
USER qcsc
WORKDIR /home/qcsc
RUN mkdir -p /home/qcsc/.cache/uv /home/qcsc/.cache/pip
RUN --mount=type=cache,target=/home/qcsc/.cache/uv,uid=1000,gid=1000 \
    --mount=type=cache,target=/home/qcsc/.cache/pip,uid=1000,gid=1000 \
    UV_VERSION="${UV_VERSION}" QCSC_PREFECT_REPO="${QCSC_PREFECT_REPO}" \
    QCSC_PREFECT_REF="${QCSC_PREFECT_REF}" QCSC_PREFECT_SHA="${QCSC_PREFECT_SHA}" \
    QRMI_PIP_VERSION="${QRMI_PIP_VERSION}" FFSIM_VERSION="${FFSIM_VERSION}" \
    FFSIM_WHEEL_DIR=/opt/wheels/ffsim \
    bash /usr/share/qcsc-cluster/setup-qcsc-user.sh

# The stamp of this build; the entrypoint warns when /home holds an older one.
USER root
WORKDIR /
RUN cp /home/qcsc/.qcsc-cluster-build /usr/share/qcsc-cluster/build
COPY --from=bundle /bundle/ /usr/share/qcsc-cluster/bundle/
