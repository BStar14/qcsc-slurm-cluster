#!/bin/bash
# Roles: slurmdbd, slurmctld, slurmd, login. Adapted from the docker-entrypoint.sh of
# giovtorres/slurm-docker-cluster (MIT). Secrets (the munge key, the SSH host keys)
# are generated on first start into volumes, never baked into the image.
set -euo pipefail

SEED=/usr/share/qcsc-cluster/slurm

log() { echo "---> $*"; }

wait_for_file() {
    local path=$1
    until [ -s "$path" ]; do
        echo "-- waiting for $path ..."
        sleep 2
    done
}

wait_for_port() {
    local host=$1 port=$2
    until (exec 3<>"/dev/tcp/$host/$port") 2>/dev/null; do
        echo "-- waiting for $host:$port ..."
        sleep 2
    done
}

# Seed /etc/slurm (a shared volume) from the image once. slurmctld owns the seed;
# the other roles wait for it, so all nodes read the same files.
seed_slurm_config() {
    if [ ! -f /etc/slurm/slurm.conf ]; then
        log "Seeding /etc/slurm from the image"
        cp -n "$SEED"/* /etc/slurm/
        chown slurm:slurm /etc/slurm/slurmdbd.conf
        chmod 600 /etc/slurm/slurmdbd.conf /etc/slurm/qrmi_config.json
        # Node size from the environment (compose passes the container limits).
        sed -i \
            -e "s/@NODE_CPUS@/${QCSC_NODE_CPUS:-4}/" \
            -e "s/@NODE_MEMORY_MB@/${QCSC_NODE_MEMORY_MB:-7000}/" \
            /etc/slurm/slurm.conf
    fi
}

# Create the munge key once in the shared /etc/munge volume.
ensure_munge_key() {
    if [ ! -s /etc/munge/munge.key ]; then
        log "Creating the munge key"
        dd if=/dev/urandom bs=1 count=1024 of=/etc/munge/munge.key status=none
    fi
    chown munge:munge /etc/munge /etc/munge/munge.key
    chmod 700 /etc/munge
    chmod 400 /etc/munge/munge.key
}

start_munge() {
    wait_for_file /etc/munge/munge.key
    mkdir -p /run/munge && chown munge:munge /run/munge
    log "Starting munged"
    gosu munge /usr/sbin/munged
}

case "${1:-login}" in
bundle)
    # The user files (compose.yml, Makefile, .devcontainer, ...) as a tar on stdout:
    #   docker run --rm <image> bundle | tar -x
    exec tar -C /usr/share/qcsc-cluster/bundle -cf - .
    ;;
slurmctld)
    ensure_munge_key
    seed_slurm_config
    start_munge
    wait_for_port slurmdbd 6819
    if ! sacctmgr --immediate --noheader list cluster format=cluster | grep -qw qcsc; then
        sacctmgr --immediate add cluster name=qcsc >/dev/null || true
    fi
    log "Starting slurmctld"
    exec gosu slurm /usr/sbin/slurmctld -i -D
    ;;
slurmdbd)
    wait_for_file /etc/slurm/slurmdbd.conf
    start_munge
    # slurmdbd.conf is shell-compatible key=value lines.
    host=$(sed -n 's/^StorageHost=//p' /etc/slurm/slurmdbd.conf)
    wait_for_port "$host" 3306
    log "Starting slurmdbd"
    exec gosu slurm /usr/sbin/slurmdbd -D
    ;;
slurmd)
    wait_for_file /etc/slurm/slurm.conf
    start_munge
    wait_for_port slurmctld 6817
    log "Starting slurmd"
    exec /usr/sbin/slurmd -D
    ;;
login)
    wait_for_file /etc/slurm/slurm.conf
    start_munge
    # Host keys persist in their own volume, so the fingerprint stays the same.
    mkdir -p /etc/ssh/keys
    [ -s /etc/ssh/keys/ssh_host_ed25519_key ] ||
        ssh-keygen -q -t ed25519 -N "" -f /etc/ssh/keys/ssh_host_ed25519_key
    [ -s /etc/ssh/keys/ssh_host_rsa_key ] ||
        ssh-keygen -q -t rsa -b 3072 -N "" -f /etc/ssh/keys/ssh_host_rsa_key
    # Docker fills a new home volume from the image. An existing volume keeps what an
    # earlier image put there, or nothing (an empty volume): recreate the home if needed.
    if [ ! -d /home/qcsc ]; then
        cp -a /etc/skel /home/qcsc
        chown -R qcsc:qcsc /home/qcsc
    fi
    if [ -f /usr/share/qcsc-cluster/build ] &&
        ! cmp -s /usr/share/qcsc-cluster/build /home/qcsc/.qcsc-cluster-build; then
        log "WARNING: /home/qcsc is not from this image, so its qcsc-prefect checkout and" \
            "environments may be missing or old. To replace them, run \`make reset-home\`," \
            "which deletes everything in /home/qcsc."
    fi
    install -d -m 700 -o qcsc -g qcsc /home/qcsc/.ssh
    if [ -n "${QCSC_AUTHORIZED_KEYS:-}" ]; then
        touch /home/qcsc/.ssh/authorized_keys
        while IFS= read -r key; do
            [ -n "$key" ] || continue
            grep -qxF "$key" /home/qcsc/.ssh/authorized_keys || echo "$key" >> /home/qcsc/.ssh/authorized_keys
        done <<<"$QCSC_AUTHORIZED_KEYS"
    fi
    [ -f /home/qcsc/.ssh/authorized_keys ] && {
        chown qcsc:qcsc /home/qcsc/.ssh/authorized_keys
        chmod 600 /home/qcsc/.ssh/authorized_keys
    }
    install -d -m 755 -o qcsc -g qcsc /shared/work
    log "Starting sshd"
    exec /usr/sbin/sshd -D -e
    ;;
*)
    exec "$@"
    ;;
esac
