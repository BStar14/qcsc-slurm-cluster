# qcsc-slurm-cluster

A small Slurm cluster in Docker for following the
[QCSC-Prefect setup guide](https://quantum.cloud.ibm.com/docs/en/guides/qcsc-prefect-setup)
and the
[QCSC-Prefect tutorial](https://quantum.cloud.ibm.com/docs/en/tutorials/manage-qcsc-workflow-with-qcsc-prefect)
on a laptop or a workstation. It gives you a login node, two compute nodes, and the
services behind them, with the same layout as a real HPC cluster: you work on the login
node, and you reach the compute nodes only through `srun` and `sbatch`.

qcsc-prefect is already installed, so you start the setup guide at Step 3.

## What is inside

| Component | Version | Notes |
|---|---|---|
| Rocky Linux | 9 | Base image, `linux/amd64` and `linux/arm64` |
| Slurm | `slurm-25-11-6-1` | slurmctld, slurmdbd (MariaDB 10.11), slurmd on `c1` and `c2`, partition `normal` |
| PMIx | 4.1.3 | `MpiDefault=pmix`, so `srun --mpi=pmix` works |
| OpenMPI | 4.1.8 | Built with Slurm and PMIx support, at `/opt/openmpi`, on `PATH` |
| QRMI SPANK plugin | spank-plugins `c3d5679`, QRMI `3deb512` | `/usr/lib64/slurm/spank_qrmi.so`, adds `srun --qpu` and `sbatch --qpu`; a count-only `qpu` GRES on each compute node |
| Toolchain | Rocky 9 packages | gcc, g++, gfortran, make, CMake, git, OpenBLAS, LAPACK, pkg-config, Python 3.12 with headers |
| OpenSSH | Rocky 9 packages | sshd on the login node, key-only, optional |
| JupyterLab | 4.6.6 | `/opt/jupyter`, optional, started by `make jupyter` |

The `qcsc` user has the following items, as after the setup guide and the install steps
of the tutorial:

| Item | Path | From |
|---|---|---|
| uv | `~/.local/bin/uv` | Setup guide, Step 2 |
| qcsc-prefect checkout, branch `main` | `~/qcsc-prefect` | Setup guide, Step 4 |
| Workflow environment, with the SQD workflow, the Fulqrum integration, and QRMI for the IQP path | `~/venv/qcsc-host` | Setup guide, Step 5, and the tutorial's "Install the SQD workflow on the workflow host". QRMI is an extra of this image; the guide installs it only in `~/venv/qcsc-node` |
| Compute-node environment: QRMI with `task_runner`, `qcsc-prefect-qiskit`, and the SQD transpilation hook | `~/venv/qcsc-node` | Setup guide, Step 8, and the tutorial's "Install the Fulqrum solver on a compute node" |
| Fulqrum with PRIMME, and `qcsc-fulqrum-solve` | `~/qcsc-prefect/packages/qcsc-prefect-fulqrum/native/fulqrum` | The tutorial's "Install the Fulqrum solver on a compute node" |

`~/venv/*.freeze.txt` lists the packages of each environment.

| Path | Shared by | Purpose |
|---|---|---|
| `/home` | login, c1, c2 | Home of the `qcsc` user: the checkout and the environments |
| `/shared` | login, c1, c2 | Shared data; the work directory of the guide is `/shared/work/qcsc-prefect` |
| `/etc/slurm` | every Slurm node | Slurm configuration and the QRMI `qrmi_config.json` |

The tutorial notebook itself runs on your own computer, in its own environment, not on
this cluster. The cluster runs the workflow.

## Quick start

You need Docker with Compose v2, `make`, and `tar`. Give Docker enough memory for both
compute nodes (8 GB each by default) and about 2 GB more for the other containers.

```bash
mkdir qcsc-demo && cd qcsc-demo
docker run --rm quay.io/boseong14/qcsc-slurm-cluster:latest bundle | tar -x
cp .env.example .env              # optional: ports, node CPUs and memory
make up
make login
```

The `docker run` command pulls the image from Quay, for `amd64` or `arm64` as your
computer needs, and extracts the files that run the cluster: `compose.yml`, the
`Makefile`, `.devcontainer/`, `.env.example`, `tests/`, and this README. Keep `-t` out of
the command, because it corrupts the tar stream. On Windows, run the commands in WSL.

The extracted `compose.yml` names the exact version of the image that it came from, for
example `quay.io/boseong14/qcsc-slurm-cluster:0.3.1`, so the cluster stays on that
version until you extract a newer bundle. To start from an older version, use its tag in
place of `latest`.

`make login` opens a shell of the `qcsc` user on the login node, the same shell that
`ssh` gives on a real cluster. `exit` leaves it, and the cluster keeps running. Without
`make`, run `docker compose up -d`, then
`docker compose exec -u qcsc -w /home/qcsc login bash -l`.

`make smoke` checks the cluster and the installation: `srun` on both nodes, an MPI program
on 2 nodes x 2 ranks, the `--qpu` option of the SPANK plugin, the shared `/home` and
`/shared`, both environments (including QRMI on the workflow host), and Fulqrum on a
compute node.

The containers are `qcsc-demo-login`, `qcsc-demo-c1`, `qcsc-demo-c2`, `qcsc-demo-slurmctld`,
`qcsc-demo-slurmdbd`, and `qcsc-demo-mysql`, and the volumes start with `qcsc-demo_`.
Inside the cluster, the hostnames are `login`, `c1`, `c2`, and so on.

## Follow the setup guide from Step 3

On the login node, follow
[Set up QCSC-Prefect on a Slurm cluster](https://quantum.cloud.ibm.com/docs/en/guides/qcsc-prefect-setup)
from Step 3. Skip the steps in the following table, because the image did them.

| Step | In this cluster |
|---|---|
| Step 1: Log in to the login node | `make login`, or one of the other ways in |
| Step 2: Install uv | Done |
| Step 3: Set the paths and create the work directory | **Do it** |
| Step 4: Clone qcsc-prefect | Done, on `main`, which holds the release |
| Step 5: Create the workflow environment | Done. Still activate it in each new shell: `source ~/venv/qcsc-host/bin/activate` |
| Step 6: Log in to Prefect | **Do it** |
| Step 7: Store the IBM Quantum credentials | **Do it**. For the Slurm path, also install the file for the SPANK plugin, as in [Choose how the workflow reaches the QPU](#choose-how-the-workflow-reaches-the-qpu) |
| Step 8: Create the compute-node environment | Done |
| Step 9: Verify the setup | **Do it** |

Then, in the tutorial's Requirements section, skip "Install the SQD workflow on the
workflow host" and "Install the Fulqrum solver on a compute node", and start at "Configure
and create the Prefect blocks on the workflow host". Use the following values in
`sqd_blocks.toml`:

| Parameter | Value |
|---|---|
| `python_executable` | `"~/venv/qcsc-node/bin/python"` |
| `queue` | `"normal"` |
| `work_dir` | `"/shared/work/qcsc-prefect"` |
| `fulqrum_executable` | `"~/qcsc-prefect/packages/qcsc-prefect-fulqrum/native/fulqrum/bin/qcsc-fulqrum-solve"` |
| `eigensolver` | `"primme"` (Fulqrum is built with PRIMME) |

Keep `project` commented out, because the cluster has no Slurm accounts. The compute nodes
are `c1` and `c2`.

## Choose how the workflow reaches the QPU

The workflow samples the QPU along one of two paths. Both use QRMI and the same
`qrmi-runtime` block, whose **Scheduler** field records the path.

| | Slurm path (`scheduler = "slurm"`) | IQP path (`scheduler = "iqp"`) |
|---|---|---|
| Who runs the QPU step | A Slurm job on a compute node, submitted with `--qpu=<backend>` | The workflow process on the login node, without a Slurm job |
| Who reaches IBM Quantum | The QRMI SPANK plugin, which the cluster administrator installs and configures | QRMI in `~/venv/qcsc-host`, directly |
| Credentials | `/etc/slurm/qrmi_config.json`, which the administrator keeps | `~/.qiskit/qrmi_config.json`, which `qcsc-qrmi login` writes |
| QPU access | The plugin acquires the QPU when the job starts, as an IBM Quantum batch, and releases it when the job ends | Each sampling job goes to IBM Quantum on its own, without a session |
| Transpilation | On the compute node | On the login node |
| Slurm accounting | `sacct` records the `qpu` resource of the job | Slurm does not see the QPU step |
| Cost | The QRMI job holds a compute node while its job waits in the IBM Quantum queue | No node is held |

### Why the Slurm path is the QCSC integration

In quantum-centric supercomputing (QCSC), the QPU is one more resource of the HPC system,
next to its CPUs and GPUs. The Slurm path makes that literal. A job requests the QPU like
any other resource, with `--qpu`, and the scheduler decides when the job runs. The
cluster administrator decides which QPUs jobs may use and with which credentials, and the
site's accounting records the use. The quantum step runs on a compute node, next to the
classical steps of the same workflow, under the same queues and policies.

The IQP path treats the QPU as a cloud service that the workflow calls from the login
node. It needs no administrator and no plugin, so it suits development, quick tests, and
HPC systems without the QRMI plugin, such as Miyabi and Fugaku today. The scheduler does
not see or plan the quantum step, though, so the IQP path does not show the integration
that the QCSC-Prefect tutorial is about.

### Slurm path

This step is for the path where the cluster administrator integrates QRMI with the Slurm
scheduler. The SPANK plugin reads only the `qrmi_config.json` that `plugstack.conf`
names, `/etc/slurm/qrmi_config.json`, never the file in your home directory. On a real
cluster, the administrator installs that file on every compute node. On this cluster, you
are the administrator, and `/etc/slurm` is one volume for all nodes. After each
`qcsc-qrmi login` or `qcsc-qrmi refresh`, run the following command on the login node.

```bash
sudo install -m 600 ~/.qiskit/qrmi_config.json /etc/slurm/qrmi_config.json
```

Without it, the QRMI job fails within seconds, and its `output.err` starts with
`spank_qrmi, resource <backend> not found in /etc/slurm/qrmi_config.json`. Keep the
`[qrmi]` table of `sqd_blocks.toml` as the example file has it.

### IQP path

The workflow reads the API key from `~/.qiskit/qrmi_config.json` when it samples, so the
`sudo install` step is not needed. In `sqd_blocks.toml`, comment out the `[qrmi]` table,
and uncomment the `[runtime]` table.

```toml
# [qrmi]

[runtime]
scheduler = "iqp"
```

Then run `sqd-create-blocks` again, and restart `sqd-deploy`. On a cluster that you set up
from the setup guide, first install QRMI in the workflow environment with
`uv pip install --python ~/venv/qcsc-host/bin/python "qrmi[ibm]"`. This image already has
it.

## Other ways in

All of them work on the same login node, as the `qcsc` user.

- **VS Code Dev Containers.** With the
  [Dev Containers extension](https://marketplace.visualstudio.com/items?itemName=ms-vscode-remote.remote-containers),
  open the `qcsc-demo` folder in VS Code and run **Dev Containers: Reopen in Container**. VS Code
  starts the cluster, or attaches to the one that `make up` started, and opens
  `~/qcsc-prefect` on the login node. Its terminals are login-node shells. Closing VS
  Code leaves the cluster running.
- **JupyterLab.** `make jupyter` starts JupyterLab on the login node and prints its URL,
  `http://127.0.0.1:8888/?token=...`. Its terminals are login-node shells, and its editor
  opens `sqd_blocks.toml`. `make jupyter-stop` stops it. JupyterLab runs from
  `/opt/jupyter`, not from your environments.
- **SSH.** `make add-key KEY=~/.ssh/id_ed25519.pub`, then `ssh -p 2222 qcsc@127.0.0.1`.

## Update to a new image

In the `qcsc-demo` folder, extract the bundle of the new image, and restart the
cluster with it. The bundle replaces `compose.yml` and the `Makefile`, and keeps your
`.env`:

```bash
docker pull quay.io/boseong14/qcsc-slurm-cluster:latest
docker run --rm quay.io/boseong14/qcsc-slurm-cluster:latest bundle | tar -x
make up
```

Docker fills the `home` volume from the image only when it creates the volume. So
`/home/qcsc` keeps the old checkout and environments, and the login node logs a warning.
To replace them, run the following command:

```bash
make reset-home
```

It deletes everything in `/home/qcsc`, including your Prefect login, the QRMI
credentials in `~/.qiskit`, and `sqd_blocks.toml`. Copy what you want to keep to `/shared`
first. `/shared` and `/etc/slurm` stay.

## Size the compute nodes

Each compute node gets `QCSC_NODE_CPUS` CPUs (default 4) and a memory limit of
`QCSC_NODE_MEM_LIMIT` (default `8g`), and Slurm advertises `QCSC_NODE_MEMORY_MB`
(default 7000). Set them in `.env` before the first `make up`. They are written into
`/etc/slurm/slurm.conf` when the `etc_slurm` volume is first created. To change them
later, edit that file (`make shell-login`, then `vi /etc/slurm/slurm.conf`) and restart
with `make down && make up`, or start over with `make clean`.

## Troubleshooting

| Symptom | Fix |
|---|---|
| `sinfo` shows `c1` or `c2` as `down` or `drain` | `make up` resumes them; or `docker compose exec slurmctld scontrol update nodename=c1 state=resume` |
| `srun: error: ... Invalid node name specified` after resizing | The node size in `slurm.conf` exceeds the container limit; lower `RealMemory` or `CPUs` |
| `Munge decode failed` | The volumes come from another cluster; `make clean`, then `make up` |
| `WARNING: /home/qcsc is not from this image` in `docker compose logs login` | See [Update to a new image](#update-to-a-new-image) |
| `make jupyter` says that port 8888 is in use | Set `JUPYTER_PORT` in `.env`, then `make down && make up` |
| SSH warns that the host key changed | The `ssh_host_keys` volume was recreated; remove the old line with `ssh-keygen -R "[127.0.0.1]:2222"` |
| A QRMI job fails, and `output.err` says `resource <backend> not found in /etc/slurm/qrmi_config.json` | The plugin's file does not list that QPU; install your file as in [Slurm path](#slurm-path), or use the [IQP path](#iqp-path) |

## Security notes

- The cluster is for local, single-user use. SSH and JupyterLab listen on `127.0.0.1`
  only. SSH accepts keys only, and JupyterLab needs its token. The `qcsc` user has
  passwordless `sudo`.
- The munge key and the SSH host keys are generated on first start, in volumes. The image
  contains no keys and no credentials.
- After you install it, `/etc/slurm/qrmi_config.json` holds your IBM Cloud API key in the
  `etc_slurm` volume, mode 600. `make clean` deletes it with every other volume.
- The Slurm accounting database uses a fixed password on the private compose network.

## Build the image

You need the image only from Quay. To build it yourself, clone the source repository,
which has the Dockerfile:

```bash
git clone https://github.com/BStar14/qcsc-slurm-cluster.git
cd qcsc-slurm-cluster
make build
```

`make build` builds the image for this machine, with qcsc-prefect `main`. Set
`QCSC_PREFECT_REF` to build another branch or tag. The build takes about an hour, mostly
for Slurm, OpenMPI and Fulqrum. The clone also runs the cluster, with the same `make`
targets as the bundle.

`make build-cluster` builds only the cluster, without uv, the environments or qcsc-prefect,
and tags it `:cluster`. Use it to follow the setup guide from Step 1.

## Publishing (maintainers)

The `publish` workflow builds `linux/amd64` and `linux/arm64` on native GitHub runners and
pushes `quay.io/boseong14/qcsc-slurm-cluster`.

1. On [quay.io](https://quay.io), create the repository `boseong14/qcsc-slurm-cluster`
   as **Public**. A repository that a push creates is private.
2. Create a robot account, for example `boseong14+github`, with **Write** permission on the
   repository.
3. In the GitHub repository, add the secrets `QUAY_USERNAME` (the robot name) and
   `QUAY_PASSWORD` (its token).
4. Tag a release, for example `git tag v0.3.1 && git push origin v0.3.1`. The workflow
   pushes `:0.3.1` and `:latest`, with qcsc-prefect `main` at that time; the image label
   `io.qcsc.qcsc-prefect.commit` records the commit. Pull requests and manual runs only
   build.

To build and push one platform by hand:

```bash
make build IMAGE=quay.io/boseong14/qcsc-slurm-cluster:dev
docker login quay.io
docker push quay.io/boseong14/qcsc-slurm-cluster:dev
```

## License

The files of this repository are under the MIT License (see `LICENSE`). The image
contains third-party software under its own licenses, including GPL-licensed Slurm and
the GPL-3.0 SPANK plugin, whose source is in the image at `/usr/src/spank-plugins`. See
`NOTICE`.
