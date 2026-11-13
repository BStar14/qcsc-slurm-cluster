# qcsc-slurm-cluster

A small Slurm cluster in Docker for following the
[QCSC-Prefect tutorial](https://quantum.cloud.ibm.com/docs/en/tutorials/manage-qcsc-workflow-with-qcsc-prefect)
on a laptop or a workstation. It gives you a login node, two compute nodes, and the
services behind them, with the same layout as a real HPC cluster: you work on the login
node, and you reach the compute nodes only through `srun` and `sbatch`.

## What is inside

| Component | Version | Notes |
|---|---|---|
| Rocky Linux | 9 | Base image, `linux/amd64` and `linux/arm64` |
| Slurm | `slurm-25-11-6-1` | slurmctld, slurmdbd (MariaDB 10.11), slurmd on `c1` and `c2`, partition `normal` |
| PMIx | 4.1.3 | `MpiDefault=pmix`, so `srun --mpi=pmix` works |
| OpenMPI | 4.1.8 | Built with Slurm and PMIx support, at `/opt/openmpi`, on `PATH` |
| QRMI SPANK plugin | spank-plugins `c3d5679`, QRMI `3deb512` | `/usr/lib64/slurm/spank_qrmi.so`, adds `srun --qpu` and `sbatch --qpu`; a count-only `qpu` GRES on each compute node |
| Toolchain | Rocky 9 packages | gcc, g++, gfortran, make, CMake, git, OpenBLAS, LAPACK, pkg-config, Python 3.12 with headers |
| Editors | Rocky 9 packages | Vim (`vim`, and `vi` in shells), with highlighting for `sqd_blocks.toml`, and nano; `EDITOR` is `vim` |
| OpenSSH | Rocky 9 packages | sshd on the login node, key-only, optional |
| JupyterLab | 4.6.6 | `/opt/jupyter`, optional, started by `make jupyter` |

The image follows
[Set up QCSC-Prefect on a Slurm cluster](https://quantum.cloud.ibm.com/docs/en/guides/qcsc-prefect-setup)
and the Requirements section of the
[QCSC-Prefect tutorial](https://quantum.cloud.ibm.com/docs/en/tutorials/manage-qcsc-workflow-with-qcsc-prefect).
It has done Steps 2, 4, 5 and 8 of the setup guide, and the tutorial's "Install the SQD
workflow on the workflow host" and "Install the Fulqrum solver on a compute node". The
preinstalled steps only make the setup faster: follow both documents as written, and the
steps that are already done finish quickly. The `qcsc` user has the following items.

| Item | Path |
|---|---|
| uv | `~/.local/bin/uv` |
| qcsc-prefect checkout, branch `main` | `~/qcsc-prefect` |
| Workflow environment, with the SQD workflow, the Fulqrum integration, and QRMI for the IQP path | `~/venv/qcsc-host` |
| Compute-node environment: QRMI with `task_runner`, `qcsc-prefect-qiskit`, and the SQD transpilation hook | `~/venv/qcsc-node` |
| Fulqrum with PRIMME, and `qcsc-fulqrum-solve` | `~/qcsc-prefect/packages/qcsc-prefect-fulqrum/native/fulqrum` |

QRMI in `~/venv/qcsc-host` is an extra of this image: the setup guide installs QRMI only in
`~/venv/qcsc-node`. `~/venv/*.freeze.txt` lists the packages of each environment.

| Path | Shared by | Purpose |
|---|---|---|
| `/home` | login, c1, c2 | Home of the `qcsc` user: the checkout and the environments |
| `/shared` | login, c1, c2 | Shared data; the work directory is `/shared/work/qcsc-prefect` |
| `/etc/slurm` | every Slurm node | Slurm configuration and the QRMI `qrmi_config.json` |

The containers are `qcsc-demo-login`, `qcsc-demo-c1`, `qcsc-demo-c2`, `qcsc-demo-slurmctld`,
`qcsc-demo-slurmdbd`, and `qcsc-demo-mysql`. Inside the cluster, the hostnames are
`login`, `c1`, `c2`, and so on.

The tutorial notebook itself runs on your own computer, in its own environment, not on
this cluster. The cluster runs the workflow.

## Quick start

You need Docker with Compose v2, `make`, and `tar`. Give Docker enough memory for both
compute nodes (8 GB each by default) and about 2 GB more for the other containers. On
Windows, run the commands in WSL.

Create a folder for the cluster.

```bash
mkdir qcsc-demo
```

```bash
cd qcsc-demo
```

Extract the files that run the cluster from the image: `compose.yml`, the `Makefile`,
`.devcontainer/`, `.env.example`, `tests/`, and this README. Docker pulls the image from
Quay for your computer, `amd64` or `arm64`. Keep `-t` out of this command, because it
corrupts the tar stream.

```bash
docker run --rm quay.io/boseong14/qcsc-slurm-cluster:latest bundle | tar -x
```

To change the ports or the size of the compute nodes, copy `.env.example` to `.env`, and
edit it before the first start.

```bash
# Optional
cp .env.example .env
```

Start the cluster. The first start takes about a minute, because it creates the Slurm
database.

```bash
make up
```

Open a shell on the login node, the same shell that `ssh` gives on a real cluster. Run the
remaining commands of this section in it. `exit` leaves the login node, and the cluster
keeps running. `make smoke` checks the cluster and the installation, and `make down`
stops the cluster.

```bash
make login
```

Go to the checkout, and activate the workflow environment.

```bash
cd ~/qcsc-prefect
source ~/venv/qcsc-host/bin/activate
```

Log in to Prefect Cloud. Choose **Paste an API key**, paste a Prefect Cloud API key, and
choose your workspace.

```bash
prefect cloud login
```

Store your IBM Quantum credentials and save the `qrmi-runtime` block, as in Step 7 of the
setup guide.

```bash
qcsc-qrmi login
```

Install your `qrmi_config.json` for the QRMI SPANK plugin. Run it again after each
`qcsc-qrmi login` or `qcsc-qrmi refresh`.

```bash
sudo install -m 600 ~/.qiskit/qrmi_config.json /etc/slurm/qrmi_config.json
```

> [!NOTE]
> This command is for the Slurm path, where QRMI is integrated with the Slurm scheduler,
> and on a real cluster only the administrator can run it. Where the Slurm path is not
> available, use the IQP path with your own credentials instead, as in
> [QRMI Runtime mode selection](#qrmi-runtime-mode-selection).

Now follow the
[QCSC-Prefect tutorial](https://quantum.cloud.ibm.com/docs/en/tutorials/manage-qcsc-workflow-with-qcsc-prefect)
on the login node, from its Requirements section to your first run. For the setup
details behind these commands, see
[Set up QCSC-Prefect on a Slurm cluster](https://quantum.cloud.ibm.com/docs/en/guides/qcsc-prefect-setup).

## QRMI Runtime mode selection

The workflow samples the QPU in one of two modes. Both use QRMI and the same
`qrmi-runtime` block, whose **Scheduler** field records the mode.

| | Slurm path (`scheduler = "slurm"`) | IQP path (`scheduler = "iqp"`) |
|---|---|---|
| Who runs the QPU step | A Slurm job on a compute node, submitted with `--qpu=<backend>` | The workflow process on the login node, without a Slurm job |
| Who reaches IBM Quantum | The QRMI SPANK plugin, which the cluster administrator installs and configures | QRMI in `~/venv/qcsc-host`, directly |
| Credentials | `/etc/slurm/qrmi_config.json`, which the administrator keeps | `~/.qiskit/qrmi_config.json`, which `qcsc-qrmi login` writes |
| QPU access | The plugin acquires the QPU when the job starts, as an IBM Quantum batch, and releases it when the job ends | Each sampling job goes to IBM Quantum on its own, without a session |
| Transpilation | On the compute node | On the login node |
| Slurm accounting | `sacct` records the `qpu` resource of the job | Slurm does not see the QPU step |
| Cost | The QRMI job holds a compute node while its job waits in the IBM Quantum queue | No node is held |

### How QRMI Slurm and IQP differ

In quantum-centric supercomputing (QCSC), the QPU is one more resource of the HPC system,
next to its CPUs and GPUs. The Slurm path makes that literal. A job requests the QPU like
any other resource, with `--qpu`, and the scheduler decides when the job runs. The
cluster administrator decides which QPUs jobs may use and with which credentials, and the
site's accounting records the use. The quantum step runs on a compute node, next to the
classical steps of the same workflow, under the same queues and policies.

The IQP path treats the QPU as a cloud service that the workflow calls from the login
node, with your own credentials. It needs no administrator and no plugin, so it suits
development, quick tests, and HPC systems without the QRMI plugin, such as Miyabi and
Fugaku today. The scheduler does not see or plan the quantum step, though, so the IQP path
does not show the integration that the QCSC-Prefect tutorial is about.

### Slurm path

The SPANK plugin reads only the `qrmi_config.json` that `plugstack.conf` names,
`/etc/slurm/qrmi_config.json`, never the file in your home directory. On a real cluster,
the administrator installs that file on every compute node. On this cluster, you are the
administrator, and `/etc/slurm` is one volume for all nodes, so the `sudo install` command
of [Quick start](#quick-start) installs it everywhere. From your computer, in the
`qcsc-demo` folder, `make qrmi-config` does the same.

Without that file, the QRMI job fails within seconds, and its `output.err` starts with
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
  open the `qcsc-demo` folder in VS Code and run **Dev Containers: Reopen in Container**.
  VS Code starts the cluster, or attaches to the one that `make up` started, and opens
  `~/qcsc-prefect` on the login node. Its terminals are login-node shells. Closing VS Code
  leaves the cluster running.
- **JupyterLab.** `make jupyter` starts JupyterLab on the login node and prints its URL,
  `http://127.0.0.1:8888/?token=...`. Its terminals are login-node shells, and its editor
  opens `sqd_blocks.toml`. `make jupyter-stop` stops it. JupyterLab runs from
  `/opt/jupyter`, not from your environments.
- **SSH.** `make add-key KEY=~/.ssh/id_ed25519.pub`, then `ssh -p 2222 qcsc@127.0.0.1`.
- **Without `make`.** `docker compose up -d`, then
  `docker compose exec -u qcsc -w /home/qcsc login bash -l`.

## Update to a new image

The extracted `compose.yml` names the exact version of the image that it came from, for
example `quay.io/boseong14/qcsc-slurm-cluster:0.3.1`, so the cluster stays on that version
until you extract a newer bundle. In the `qcsc-demo` folder, extract the bundle of the new image, and restart the cluster
with it. The bundle replaces `compose.yml` and the `Makefile`, and keeps your `.env`.

```bash
docker pull quay.io/boseong14/qcsc-slurm-cluster:latest
docker run --rm quay.io/boseong14/qcsc-slurm-cluster:latest bundle | tar -x
make up
```

Docker fills the `home` volume from the image only when it creates the volume. So
`/home/qcsc` keeps the old checkout and environments, and the login node logs a warning.
To replace them, run the following command.

```bash
make reset-home
```

It deletes everything in `/home/qcsc`, including your Prefect login, the QRMI
credentials in `~/.qiskit`, and `sqd_blocks.toml`. Copy what you want to keep to `/shared`
first. `/shared` and `/etc/slurm` stay.

## Troubleshooting

| Symptom | Fix |
|---|---|
| `make up` says that the Slurm controller is not up | Read the logs that it names; a full Docker disk stops MariaDB with `No space left on device` |
| `sinfo` shows `c1` or `c2` as `down` or `drain` | `make up` resumes them; or `docker compose exec slurmctld scontrol update nodename=c1 state=resume` |
| `Munge decode failed` | The volumes come from another cluster; `make clean`, then `make up` |
| `WARNING: /home/qcsc is not from this image` in `docker compose logs login` | See [Update to a new image](#update-to-a-new-image) |
| A QRMI job fails, and `output.err` says `resource <backend> not found in /etc/slurm/qrmi_config.json` | The plugin's file does not list that QPU; run the `sudo install` command of [Quick start](#quick-start), or use the [IQP path](#iqp-path) |
| A solver job fails with `QCSC Prefect preflight failed: executable '~/...' does not exist` | A block form in Prefect Cloud does not expand `~`. Write the absolute path that `realpath` prints, for example `/home/qcsc/qcsc-prefect/...` |
| `make jupyter` says that port 8888 is in use | Set `JUPYTER_PORT` in `.env`, then `make down && make up` |
| SSH warns that the host key changed | The `ssh_host_keys` volume was recreated; remove the old line with `ssh-keygen -R "[127.0.0.1]:2222"` |

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
which has the Dockerfile.

```bash
git clone https://github.com/BStar14/qcsc-slurm-cluster.git
cd qcsc-slurm-cluster
make build
```

`make build` builds the image for this machine, with qcsc-prefect `main`. Set
`QCSC_PREFECT_REF` to build another branch or tag. The build takes about an hour, mostly
for Slurm, OpenMPI and Fulqrum. `make build-cluster` builds only the cluster, without uv,
the environments or qcsc-prefect, and tags it `:cluster`.

## License

The files of this repository are under the MIT License (see `LICENSE`). The image
contains third-party software under its own licenses, including GPL-licensed Slurm and
the GPL-3.0 SPANK plugin, whose source is in the image at `/usr/src/spank-plugins`. See
`NOTICE`.
