# 3-node Apache NiFi cluster on a single-host Docker Swarm

Three NiFi 2.10.0 nodes, mTLS-secured, coordinated by a single ZooKeeper
instance, deployed as a Swarm stack on one machine.

## How this differs from the single-node project

If you've been through the single-node mTLS setup already, most of the
concepts carry over - but three things are genuinely different here,
and are the most likely places to trip up if skipped:

1. **`docker stack deploy` does NOT read `.env` automatically.**
   `docker compose up` does this for you; Swarm does not. You must
   export the variables into your shell first (see "Deploy" below), or
   every `${VARIABLE}` in `docker-stack.yml` silently becomes blank.
2. **One shared certificate for all 3 nodes, not one each.** NiFi's
   docker image only supports a single `NODE_IDENTITY` environment
   variable per node (confirmed directly from `secure.sh`'s source) -
   there's no `NODE_IDENTITY_2`, `NODE_IDENTITY_3`, etc. Rather than
   hand-editing `authorizers.xml` after boot to register 3 separate
   identities, all 3 nodes are issued the *same* certificate (one CN,
   multi-SAN covering every node's service name). This is the officially
   documented approach for same-host clusters, not a shortcut - see
   [Apache NiFi's own secure cluster guide](https://bryanbende.com/development/2018/10/23/apache-nifi-secure-cluster-setup)
   for the same technique.
3. **`ulimits` and `mem_limit` don't exist in Swarm mode at all.**
   Both are `docker compose`/`docker run`-only. Swarm's equivalent for
   memory is `deploy.resources.limits.memory` (already set per node
   below); there's no per-service equivalent for `ulimits` - see the
   note near the bottom if you need it.

## 1. Initialize Swarm (if you haven't already)

```bash
docker swarm init
```
If this errors about multiple network interfaces, add
`--advertise-addr <your-ip>` - `ip addr` will show your options.

## 2. Generate the certs

```bash
chmod +x scripts/generate-cluster-certs.sh
./scripts/generate-cluster-certs.sh
```

This produces `certs/node-shared.p12` (used by all 3 nodes),
`certs/truststore.jks`, `certs/admin.p12` (your browser login cert), and
`.env` with all the passwords and identities.

## 3. Deploy

```bash
set -a
source .env
set +a
docker stack deploy -c docker-stack.yml nifi-cluster
```

The `set -a`/`set +a` pair exports every variable from `.env` into your
current shell for the one `docker stack deploy` command to pick up -
this is the step that replaces `docker compose`'s automatic `.env`
loading.

## 4. Watch it come up

```bash
docker stack services nifi-cluster
docker service logs -f nifi-cluster_nifi-node1
```
Cluster formation takes longer than a single node - each node has to
find ZooKeeper, participate in a flow election (up to the 1-minute
`NIFI_ELECTION_MAX_WAIT` window), and agree on a Cluster Coordinator.
Expect a couple of minutes before all 3 are fully joined. Watch for log
lines mentioning `Cluster Coordinator` and `flow election`.

## 5. Import the admin cert and log in

Same as the single-node project: import `certs/admin.p12` (password:
`ADMIN_P12_PASSWORD` in `.env`) into your browser, trust `certs/ca.crt`,
then visit any of:
```
https://localhost:8443/nifi   (nifi-node1)
https://localhost:8444/nifi   (nifi-node2)
https://localhost:8445/nifi   (nifi-node3)
```
All three should show the same flow canvas and the same cluster state -
that's the point of clustering. The top-right of the UI shows a cluster
icon; click it to see all 3 nodes listed as connected.

## Troubleshooting

**A node won't join the cluster / stays "disconnected":**
```bash
docker service logs nifi-cluster_nifi-node2 | grep -i "cluster\|zookeeper" | tail -30
```
Confirm all 3 nodes show the same `NODE_IDENTITY` value (they should,
since it's the identical shared cert) and that ZooKeeper is reachable:
```bash
docker service logs nifi-cluster_zookeeper | tail -20
```

**"Insufficient Permissions" logging in, same as the single-node project:**
Same root cause as before - get the ground-truth identity NiFi actually
parsed rather than guessing:
```bash
docker exec $(docker ps -q -f name=nifi-cluster_nifi-node1) \
  grep -i identity /opt/nifi/nifi-current/logs/nifi-user.log | tail -5
```

**Need the `ulimits` NiFi's Admin Guide recommends:** Swarm has no
per-service `ulimits` field. The Swarm-native equivalent is setting
`default-ulimits` in Docker's own daemon config (affects every
container on the host, not just this stack):
```json
// /etc/docker/daemon.json
{
  "default-ulimits": {
    "nofile": { "Name": "nofile", "Hard": 50000, "Soft": 50000 },
    "nproc": { "Name": "nproc", "Hard": 10000, "Soft": 10000 }
  }
}
```
Then `sudo systemctl restart docker` (this restarts every running
container on the host, not just this stack - plan accordingly).

## CI/CD

`.github/workflows/ci.yml` has the same two-job pattern as the
single-node project, adapted for a 3-node cluster:

**`validate`** runs on every push/PR, on GitHub's own hosted runner. It
shellchecks the cert script, initializes a throwaway single-node Swarm
inside the CI runner itself, deploys the full stack (ZooKeeper + all 3
NiFi nodes), waits for all 3 published ports to come up, confirms the
shared node identity seeded correctly, then tears everything down. This
is slower than the single-node project's equivalent job - budget several
minutes, since it's booting 3 JVMs plus ZooKeeper and waiting through a
real cluster flow election, not just one node.

**`deploy`** only runs on push to `main`, on a self-hosted runner.

### This repo needs its OWN self-hosted runner - important

If you already set up a self-hosted runner for the single-node NiFi
project, **it will not pick up jobs for this repo**, even though it's
the same physical ZBook. On a personal GitHub account, self-hosted
runners are registered per-repository, not shared globally across all
your repos. You need to repeat the runner setup once more, specifically
for this repo:

1. This repo on GitHub → **Settings → Actions → Runners → New self-hosted runner**
2. Follow the commands it gives you, but install into a **different
   folder** than your other runner (e.g. `~/actions-runner-cluster`
   instead of `~/actions-runner`) - two runner installs can coexist on
   the same machine, they just each need their own directory.
3. Give it the label `zbook` again (matching `runs-on: [self-hosted, zbook]`
   in this repo's `ci.yml` - the label name doesn't need to be globally
   unique, only to match what each repo's own workflow expects).
4. Install as a service so it survives reboots:
   ```bash
   sudo ./svc.sh install
   sudo ./svc.sh start
   ```

### Resource contention if both projects run at once

If the single-node NiFi project's container is *also* running on this
same ZBook at the same time as this 3-node cluster, you're now running
4+ NiFi JVMs plus ZooKeeper concurrently on one machine. Check your
available RAM before deploying both - stop the single-node project
first (`docker compose down`, in that project's folder) if you hit
memory pressure.

## Tearing down

```bash
docker stack rm nifi-cluster
```
This leaves the named volumes (and therefore all 3 nodes' state/flow)
intact for next time. Add `docker volume prune` afterward only if you
genuinely want to wipe everything and start fresh.

## Resource note

Three NiFi JVMs (768m-1.5g heap each) plus ZooKeeper running
concurrently on one machine adds up - budget at least 6-8GB of RAM
available for this stack alone before starting it, on top of whatever
else is running on your ZBook. Adjust `NIFI_JVM_HEAP_INIT` /
`NIFI_JVM_HEAP_MAX` and each node's `deploy.resources.limits.memory` in
`docker-stack.yml` if you need to scale that up or down.
