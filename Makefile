# qcsc-slurm-cluster helpers. Run `make help` for the targets.
SHELL := /bin/bash
COMPOSE ?= docker compose
-include .env
IMAGE ?= $(or $(QCSC_CLUSTER_IMAGE),quay.io/boseong14/qcsc-slurm-cluster:latest)
KEY ?= $(HOME)/.ssh/id_ed25519.pub
JUPYTER_PORT ?= 8888
QCSC_PREFECT_REPO ?= https://github.com/qiskit-community/qcsc-prefect.git
QCSC_PREFECT_REF ?= main
# The tag of `build-cluster`.
CLUSTER_IMAGE = $(firstword $(subst :, ,$(IMAGE))):cluster
# The project name of compose.yml, for the home volume of `reset-home`.
PROJECT := qcsc-demo

# The build targets need the source repository; the bundle from the image has no Dockerfile.
NEED_SOURCE = @test -f Dockerfile || { echo "No Dockerfile here: build from a clone of" \
	"https://github.com/BStar14/qcsc-slurm-cluster, or pull the image instead"; exit 1; }

# The SPANK plugin's file (plugstack.conf), the empty one the image seeds it with, and the
# qcsc user's file from `qcsc-qrmi login`.
QRMI_PLUGIN_CONFIG := /etc/slurm/qrmi_config.json
QRMI_SEED := /usr/share/qcsc-cluster/slurm/qrmi_config.json
QRMI_USER_CONFIG := /home/qcsc/.qiskit/qrmi_config.json

# A login shell of the qcsc user on the login node, as after `ssh`.
LOGIN_SHELL = $(COMPOSE) exec -u qcsc -w /home/qcsc login bash -l

.PHONY: help build build-cluster up down clean reset-home status login shell-login \
	qrmi-config add-key jupyter jupyter-stop logs smoke

help:
	@echo "build          build $(IMAGE) for this machine, with qcsc-prefect $(QCSC_PREFECT_REF)"
	@echo "build-cluster  build the cluster only (no uv, venvs or qcsc-prefect), tag :cluster"
	@echo "up             start the cluster and resume c1, c2"
	@echo "login          shell of the qcsc user on login, as after ssh"
	@echo "down           stop the cluster (volumes kept)"
	@echo "reset-home     DELETE /home/qcsc and refill it from the image (after a new image)"
	@echo "clean          stop the cluster and DELETE all volumes, including /home and /shared"
	@echo "status         sinfo and squeue"
	@echo "qrmi-config    Slurm path: install ~/.qiskit/qrmi_config.json for the SPANK plugin"
	@echo "jupyter        start JupyterLab on login and print its URL; jupyter-stop stops it"
	@echo "add-key        add KEY=$(KEY) to the qcsc user's authorized_keys, for ssh"
	@echo "shell-login    root shell on login"
	@echo "logs           follow the service logs"
	@echo "smoke          run the cluster and qcsc-prefect checks as the qcsc user"

# QCSC_PREFECT_SHA keys the build cache to the current commit of QCSC_PREFECT_REF: the
# branch, else the commit of the tag (^{} for an annotated tag).
build:
	$(NEED_SOURCE)
	@sha=$$(git ls-remote "$(QCSC_PREFECT_REPO)" | awk -v r="$(QCSC_PREFECT_REF)" \
	    '$$2 == "refs/heads/" r {h = $$1} $$2 == "refs/tags/" r "^{}" {p = $$1} \
	     $$2 == "refs/tags/" r {t = $$1} END {print h ? h : (p ? p : t)}'); \
	  test -n "$$sha" || { echo "no branch or tag $(QCSC_PREFECT_REF) in $(QCSC_PREFECT_REPO)"; exit 1; }; \
	  echo "qcsc-prefect $(QCSC_PREFECT_REF) at $$sha"; \
	  docker buildx build --load -t $(IMAGE) --build-arg QCSC_CLUSTER_IMAGE="$(IMAGE)" \
	    --build-arg QCSC_PREFECT_REPO="$(QCSC_PREFECT_REPO)" \
	    --build-arg QCSC_PREFECT_REF="$(QCSC_PREFECT_REF)" \
	    --build-arg QCSC_PREFECT_SHA="$$sha" .

build-cluster:
	$(NEED_SOURCE)
	docker buildx build --load --target cluster -t $(CLUSTER_IMAGE) \
	  --build-arg QCSC_CLUSTER_IMAGE="$(CLUSTER_IMAGE)" .

# Waits up to 2 minutes for slurmctld (the first start initializes MariaDB), and stops
# early if a container exits, with its status and where to look.
up:
	$(COMPOSE) up -d
	@for i in $$(seq 60); do \
	  $(COMPOSE) exec -T slurmctld scontrol ping >/dev/null 2>&1 && exit 0; \
	  [ -n "$$($(COMPOSE) ps -a -q --status exited)" ] && break; sleep 2; done; \
	  echo "The Slurm controller is not up. Containers:"; \
	  $(COMPOSE) ps -a --format '  {{.Name}}: {{.Status}}'; \
	  echo "See the logs with: $(COMPOSE) logs mysql slurmdbd slurmctld"; exit 1
	@for n in c1 c2; do $(COMPOSE) exec -T slurmctld scontrol update nodename=$$n state=resume 2>/dev/null || true; done
	@$(COMPOSE) exec -T login sinfo
	@$(COMPOSE) exec -T login bash -c '[ "$$(cat $(QRMI_SEED))" != "$$(cat $(QRMI_PLUGIN_CONFIG))" ]' \
	  || echo "Slurm path: the SPANK plugin has no QPUs yet. After qcsc-qrmi login, run on the login node:" \
	          "sudo install -m 600 ~/.qiskit/qrmi_config.json /etc/slurm/qrmi_config.json"

login:
	$(LOGIN_SHELL)

down:
	$(COMPOSE) down

reset-home:
	@read -p "Delete /home/qcsc (checkout, venvs, Prefect login, sqd_blocks.toml)? [y/N] " a && [ "$$a" = y ]
	$(COMPOSE) down
	docker volume rm $(PROJECT)_home
	$(MAKE) up

clean:
	@read -p "Delete all volumes, including /home and /shared? [y/N] " a && [ "$$a" = y ]
	$(COMPOSE) down -v

status:
	$(COMPOSE) exec -T login sinfo
	$(COMPOSE) exec -T login squeue

# The Slurm path's administrator step: copy the user's qrmi_config.json to the file that
# the SPANK plugin reads; /etc/slurm is one volume for all nodes. Never prints the file.
qrmi-config:
	@$(COMPOSE) exec -T login bash -c 'test -s $(QRMI_USER_CONFIG) || { \
	  echo "No $(QRMI_USER_CONFIG) yet: run qcsc-qrmi login on the login node first."; exit 1; }; \
	  install -m 600 -o root -g root $(QRMI_USER_CONFIG) $(QRMI_PLUGIN_CONFIG) && \
	  echo "Installed $(QRMI_USER_CONFIG) as $(QRMI_PLUGIN_CONFIG) for the SPANK plugin on c1 and c2."'

add-key:
	@test -f "$(KEY)" || { echo "no public key at $(KEY); pass KEY=path/to/key.pub"; exit 1; }
	$(COMPOSE) exec -T login bash -c 'install -d -m700 -o qcsc -g qcsc /home/qcsc/.ssh; \
	  touch /home/qcsc/.ssh/authorized_keys; k=$$(cat); \
	  grep -qxF "$$k" /home/qcsc/.ssh/authorized_keys || echo "$$k" >> /home/qcsc/.ssh/authorized_keys; \
	  chown qcsc:qcsc /home/qcsc/.ssh/authorized_keys; chmod 600 /home/qcsc/.ssh/authorized_keys' < "$(KEY)"
	@echo "ssh -p $(or $(SSH_PORT),2222) qcsc@127.0.0.1"

# JupyterLab from /opt/jupyter, as the qcsc user, with login shells in its terminals.
jupyter:
	@$(COMPOSE) exec -T -u qcsc login /opt/jupyter/bin/jupyter server list 2>/dev/null | grep -q :8888/ || \
	  $(COMPOSE) exec -d -u qcsc -w /home/qcsc login bash -lc \
	    'exec /opt/jupyter/bin/jupyter lab --ip=0.0.0.0 --port=8888 --no-browser \
	      --ServerApp.terminado_settings="{\"shell_command\": [\"/bin/bash\", \"-l\"]}" \
	      > /tmp/jupyterlab.log 2>&1'
	@for i in $$(seq 30); do \
	  url=$$($(COMPOSE) exec -T -u qcsc login /opt/jupyter/bin/jupyter server list 2>/dev/null \
	    | grep -o 'http://[^ ]*:8888/?token=[0-9a-f]*' | head -1); \
	  [ -n "$$url" ] && { echo "$$url" | sed 's#//[^/]*:8888/#//127.0.0.1:$(JUPYTER_PORT)/#'; exit 0; }; \
	  sleep 1; done; \
	  echo "JupyterLab did not start; see /tmp/jupyterlab.log on login"; exit 1

jupyter-stop:
	$(COMPOSE) exec -T -u qcsc login /opt/jupyter/bin/jupyter server stop 8888

shell-login:
	$(COMPOSE) exec login bash

logs:
	$(COMPOSE) logs -f

smoke:
	$(COMPOSE) cp tests/mpi_hello.c login:/tmp/mpi_hello.c
	$(COMPOSE) exec -T -u qcsc -w /home/qcsc login bash -lc 'set -euo pipefail; \
	  echo "== sinfo"; sinfo; \
	  echo "== srun -N2 hostname"; srun -N2 hostname | sort; \
	  echo "== MPI hello, 2 nodes x 2 ranks"; mpicc -o ~/mpi_hello /tmp/mpi_hello.c; \
	  srun --mpi=pmix -N2 -n4 ~/mpi_hello | sort; rm -f ~/mpi_hello; \
	  echo "== SPANK QRMI plugin (--qpu option)"; srun --help | grep -- --qpu; \
	  echo "== shared /home and /shared"; echo ok > /shared/work/.smoke; \
	  srun -N2 bash -c "echo \$$(hostname) home=\$$(test -d ~/qcsc-prefect && echo ok) shared=\$$(cat /shared/work/.smoke)" | sort; \
	  rm -f /shared/work/.smoke; \
	  echo "== toolchain"; gcc --version | head -1; cmake --version | head -1; python3.12 --version; \
	  echo "== qcsc-prefect $$(git -C ~/qcsc-prefect log -1 --format="%h %cs")"; uv --version; \
	  echo "== ~/venv/qcsc-host"; \
	  ls ~/venv/qcsc-host/bin/{prefect,qcsc-qrmi,sqd-create-blocks,sqd-deploy}; \
	  ~/venv/qcsc-host/bin/python -c "import ffsim, qrmi, sqd_common, qcsc_prefect_executor; ffsim.FermionOperator({(): 1.0}); print(\"imports ok\")"; \
	  echo "== ~/venv/qcsc-node on c1"; \
	  srun -N1 -w c1 ~/venv/qcsc-node/bin/python -c "import qrmi, qcsc_prefect.integrations.qiskit.qrmi.worker, sqd_common.transpile; print(\"imports ok\")"; \
	  srun -N1 -w c1 ls ~/venv/qcsc-node/bin/task_runner; \
	  echo "== Fulqrum on c2"; \
	  srun -N1 -w c2 ~/qcsc-prefect/packages/qcsc-prefect-fulqrum/native/fulqrum/bin/qcsc-fulqrum-solve --help >/dev/null; \
	  srun -N1 -w c2 ~/qcsc-prefect/packages/qcsc-prefect-fulqrum/native/fulqrum/bin/python -c "import fulqrum, primme; print(\"fulqrum\", fulqrum.__version__)"; \
	  echo "smoke ok"'
