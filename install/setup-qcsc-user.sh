#!/bin/bash
# Preinstall qcsc-prefect for the qcsc user, at image build time. Runs as qcsc in /home/qcsc.
#
# Follows "Set up QCSC-Prefect on a Slurm cluster" (Steps 2, 4, 5 and 8) and the
# Requirements section of the QCSC-Prefect tutorial (the SQD workflow, the transpilation
# hook, and the Fulqrum build), so users start at Step 3 of the setup guide.
# Users do Step 3 (variables and work directory), Steps 6 and 7 (Prefect and IBM Quantum
# logins) and Step 9 (verify) themselves.
#
# Environment (from the Dockerfile):
#   UV_VERSION          uv release to install
#   QCSC_PREFECT_REPO   qcsc-prefect git URL
#   QCSC_PREFECT_REF    branch or tag to clone
#   QCSC_PREFECT_SHA    commit that QCSC_PREFECT_REF must resolve to (optional)
#   QRMI_PIP_VERSION    qrmi release for ~/venv/qcsc-node, matching the SPANK plugin
#   FFSIM_WHEEL_DIR     directory with the ffsim wheel to install in ~/venv/qcsc-host
#   FFSIM_VERSION       version of that wheel
set -euo pipefail

: "${UV_VERSION:?}" "${QCSC_PREFECT_REPO:?}" "${QCSC_PREFECT_REF:?}"
: "${QRMI_PIP_VERSION:?}" "${FFSIM_WHEEL_DIR:?}" "${FFSIM_VERSION:?}"

step() { echo; echo "=== $*"; }

# Build-time settings only; users get uv's defaults. The uv cache is a BuildKit cache
# mount on another file system, so copy instead of hardlinking, and never download a
# Python: every venv uses the image's /usr/bin/python3.12, the same on every node.
export UV_LINK_MODE=copy UV_PYTHON_DOWNLOADS=never

# Whether a shared library has Arm SVE instructions (the PyPI aarch64 ffsim wheel does,
# and they raise SIGILL on CPUs without SVE, such as Apple Silicon).
has_sve() {
    objdump -d --no-show-raw-insn "$1" | grep -qE '\s(index|ptrue|whilelo|whilelt|ld1d|st1d)\s+[zp][0-9]'
}

step "Step 2: Install uv $UV_VERSION"
curl -LsSf "https://astral.sh/uv/${UV_VERSION}/install.sh" | sh
# shellcheck disable=SC1091
source "$HOME/.local/bin/env"
uv --version

# The variables of Step 3, for this script only. Users set them in their own shells.
QCSC_PREFECT="$HOME/qcsc-prefect"

step "Step 4: Clone qcsc-prefect ($QCSC_PREFECT_REF)"
git clone -b "$QCSC_PREFECT_REF" "$QCSC_PREFECT_REPO" "$QCSC_PREFECT"
if [ -n "${QCSC_PREFECT_SHA:-}" ]; then
    head=$(git -C "$QCSC_PREFECT" rev-parse HEAD)
    if [ "$head" != "$QCSC_PREFECT_SHA" ]; then
        echo "error: $QCSC_PREFECT_REF is at $head, not QCSC_PREFECT_SHA=$QCSC_PREFECT_SHA;" \
            "it moved during the build, so build again" >&2
        exit 1
    fi
fi
git -C "$QCSC_PREFECT" log -1 --format='%H %s'
cd "$QCSC_PREFECT"

step "Step 5: Create ~/venv/qcsc-host"
uv venv ~/venv/qcsc-host -p 3.12
# shellcheck disable=SC1090
source ~/venv/qcsc-host/bin/activate
# All internal packages in one command, so their exact == pins resolve to this checkout.
# Not --no-deps: that would leave out Prefect and the other third-party dependencies.
uv pip install \
    -e packages/qcsc-prefect-core -e packages/qcsc-prefect-adapters \
    -e packages/qcsc-prefect-blocks -e packages/qcsc-prefect-executor \
    -e 'packages/qcsc-prefect-qiskit[slurm]'
which prefect qcsc-qrmi

step "Step 8: Create ~/venv/qcsc-node"
uv venv ~/venv/qcsc-node -p 3.12
# One command, not the guide's two: alone, qrmi[ibm] (qiskit-ibm-runtime>=0.30) resolved to
# qiskit-ibm-runtime 0.45.1 and the sdist-only ibm-platform-services 0.55.2, whose setup.py
# needs pkg_resources, gone from current setuptools. Together with qcsc-prefect-qiskit
# (qiskit-ibm-runtime>=0.46) it resolves as in ~/venv/qcsc-host. --only-binary
# makes uv choose an ibm-platform-services wheel (0.55.3 and later) rather than build one.
uv pip install --python ~/venv/qcsc-node/bin/python --only-binary ibm-platform-services \
    "qrmi[ibm]==${QRMI_PIP_VERSION}" -e packages/qcsc-prefect-qiskit

step "Tutorial: Install the SQD workflow on the workflow host"
# ffsim first, from the wheel of the image's ffsim stage (built from source on arm64).
# The SQD install keeps it, since it already satisfies the unpinned requirement.
uv pip install "$FFSIM_WHEEL_DIR"/ffsim-"${FFSIM_VERSION}"-*.whl
uv pip install --no-deps -e packages/qcsc-prefect-fulqrum
uv pip install -e algorithms/qcsc_workflow_utility
uv pip install -e algorithms/open_loop/sqd
which sqd-create-blocks sqd-deploy
installed=$(python -c "from importlib.metadata import version; print(version('ffsim'))")
[ "$installed" = "$FFSIM_VERSION" ] || {
    echo "error: the SQD install replaced ffsim $FFSIM_VERSION with $installed" >&2
    exit 1
}
if [ "$(uname -m)" = aarch64 ]; then
    for so in ~/venv/qcsc-host/lib/python3.12/site-packages/ffsim/_lib*.so; do
        if has_sve "$so"; then
            echo "error: $so has SVE instructions" >&2
            exit 1
        fi
    done
fi
# ffsim has no __version__; $installed is its version from the package metadata.
python -c "import ffsim; ffsim.FermionOperator({(): 1.0})"
echo "ffsim $installed: FermionOperator ok"

step "Tutorial: Add the transpilation hook to ~/venv/qcsc-node"
uv pip install --python ~/venv/qcsc-node/bin/python --no-deps -e algorithms/open_loop/sqd
~/venv/qcsc-node/bin/python -c \
    "import qrmi, qcsc_prefect.integrations.qiskit.qrmi.worker, sqd_common.transpile"
ls ~/venv/qcsc-node/bin/task_runner
deactivate

step "Tutorial: Build Fulqrum with PRIMME"
PYTHON=python3.12 FULQRUM_WITH_PRIMME=1 bash packages/qcsc-prefect-fulqrum/native/build_fulqrum.sh
realpath packages/qcsc-prefect-fulqrum/native/fulqrum/bin/qcsc-fulqrum-solve

step "Record the installed packages"
for v in qcsc-host qcsc-node; do
    uv pip freeze --python ~/venv/$v/bin/python > ~/venv/$v.freeze.txt
done
packages/qcsc-prefect-fulqrum/native/fulqrum/bin/python -m pip freeze \
    > ~/venv/fulqrum.freeze.txt
# The entrypoint compares this stamp with the image's, to spot an older /home volume.
git -C "$QCSC_PREFECT" rev-parse HEAD > ~/.qcsc-cluster-build
