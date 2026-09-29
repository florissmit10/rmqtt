# rmqtt Operator: Users and ACLs

Plan for a Kubernetes operator, written in Rust, that manages users and permissions for an rmqtt cluster deployed with the Helm chart in `charts/rmqtt`.

## Decisions so far

- **Delivery mechanism: render and reload (option A).** The operator writes `rmqtt-acl.toml` into a Secret and asks each node to reload it through the HTTP API. The brokers must keep working when the operator is down, so an auth service on every connection (`rmqtt-auth-http`) was rejected.
- **Language: Rust**, using `kube-rs`.
- **Target scale:** our own use is about 10 users that rarely change, but the operator should cover the common use cases so others can use it.
- **Revocation:** deleting a user blocks new connections only. Live sessions are not kicked for now.

## Scope

- **v1:** users and permissions for a cluster that was already deployed with the Helm chart.
- **Later:** the operator runs the cluster itself (StatefulSet, scaling, split-brain detection).
- **Not planned:** kicking revoked users' sessions, and hashed passwords. Hashing needs an upstream change to `rmqtt-acl`, which we could propose separately.

## Background: what the broker offers

- **The gRPC port (5363) is not an API.** It is a private protocol between nodes: one generic byte-passing service whose payloads are Rust enums (`Message` / `MessageReply`, `rmqtt/src/grpc.rs:506`) encoded with postcard. There are no `.proto` definitions, no stable message numbering, and no authentication or TLS.
- **The HTTP API (port 6060) is the management surface** (`rmqtt-plugins/rmqtt-http-api/src/api.rs:118`). Access is one shared bearer token.

| Need | Endpoint |
|---|---|
| Cluster membership | `GET /api/v1/nodes`, `/api/v1/brokers` |
| Per-node health | `GET /api/v1/health/check/{id}` |
| Reload a plugin's config from disk | `PUT /api/v1/plugins/{node}/{plugin}/config/reload` (`rmqtt-acl/src/lib.rs:90`) |
| Read the config a plugin has loaded | `GET /api/v1/plugins/{node}/{plugin}/config` |
| Kick a client (future) | `DELETE /api/v1/clients/{clientid}` |

- **Environment variables cannot carry ACL rules.** Plugin config comes from exactly one file plus environment variables (`rmqtt/src/plugin.rs:755-793`). Env vars can only replace whole top-level keys. `rmqtt-acl` registers no list keys, so a `rules` value arrives as a string and `parse_rules` silently produces zero rules. This was confirmed with the real binary. Scalars such as the HTTP API token do work.

## Step 0: checks before building

Already confirmed while building and testing the Helm chart:

- A `{ user, password }` allow rule lets a client connect when `allow_anonymous = false`. Wrong or missing passwords are refused.
- `GET .../config` returns the loaded rules, so the operator can verify a reload took effect.
- Environment variables are ruled out for rules (see above).

Still to check:

1. Whether the `%u` and `%c` placeholders (username and client ID) work in topic filters. The per-user topic prefix preset depends on this.
2. What reload does with invalid TOML: return an error, or keep the old config silently.
3. Whether a reloaded ACL applies to clients that are already connected.
4. Whether the config parser rejects unknown fields.
5. Whether the published `rmqtt-acl` crate exposes its config types, so the operator can validate files with the broker's own parser.

## Custom resources

Namespaced, in an API group such as `mqtt.<domain>/v1alpha1` (domain to be decided).

- **`RmqttUser`**
  - `clusterRef`, `username`.
  - Password source, exactly one of:
    - `secretRef` (name and key), or
    - `generate: true`: the operator creates a random password and writes a Secret with host, port, username and password for applications to mount.
  - `superuser: bool`.
  - Optional inline `permissions`.
- **`RmqttAcl`**
  - `clusterRef`, `priority`, and an ordered list of rules.
  - Each rule has: allow or deny; who it applies to (user, client ID, IP range, protocol, or all); an action (connect, publish, subscribe, pubsub, or all); and topic filters, with placeholders.
- **`RmqttCluster`** (thin in v1)
  - How to reach the cluster: the headless Service, the API port, and a reference to the Secret holding the API token.
  - The name of the ACL Secret the operator owns.
  - Status: the nodes it found and the ACL version each node has loaded.

Validation uses CEL rules in the resource definitions rather than an admission webhook. Examples: username format, allowed actions, exactly one password source.

## Presets for common use cases

Built in, and extendable with your own `RmqttAcl` rules:

- **Default deny:** always the last rule; cannot be removed.
- **Own topic prefix:** a user may publish and subscribe only under `<prefix>/%u/#` (depends on Step 0, item 1).
- **Read-only or write-only users.**
- **Monitoring access:** subscribe to `$SYS/#`.
- **Superuser:** for admin or bridge accounts.
- **Break-glass account:** configured in the Helm chart, not by the operator, so there is always a way in if the operator is broken.

## Reconciliation

1. Watch `RmqttUser`, `RmqttAcl`, the password Secrets they reference, and `RmqttCluster`.
2. For each cluster, build the rule list:
   - superusers first;
   - then `RmqttAcl` rules by `priority`, ties broken by name so the order is stable;
   - then each user's own permissions;
   - then default deny.
   Sort so the same inputs always produce an identical file, and hash it.
3. Validate the file, with `rmqtt-acl`'s own types if available (Step 0, item 5), otherwise with the `toml` crate plus our own structs. If it is invalid, mark the resource as failed and leave the running config untouched.
4. Update the ACL Secret, with the hash as an annotation.
5. Roll it out to each node, discovered through the headless Service's endpoints:
   - call `PUT /api/v1/plugins/{node}/rmqtt-acl/config/reload`;
   - call `GET .../config` and compare it with the intended rules;
   - if they differ, the mounted file has not updated yet (Kubernetes can take about a minute), so retry with backoff.
6. Status:
   - record which hash each node has loaded;
   - set a `Synced` condition, true only when every node matches;
   - emit Kubernetes Events for failures.
7. Report problems on the resource's status: duplicate usernames across `RmqttUser`s, a missing password Secret, an unreachable cluster.

Pods that restart read the current file at startup, so they are consistent without extra steps.

## Changes to the Helm chart

- Add a value `acl.mode: static | operator`.
  - `static` is today's behaviour: an init container fills password placeholders into a file on an in-memory volume at pod start.
  - `operator` mounts the operator-owned Secret directly. The init-container approach cannot be used here, because it writes the file once and later reloads would keep reading the old file.
- The Secret must be mounted as a whole directory, not with `subPath`, because `subPath` mounts never receive updates.
- The checksum annotation that rolls pods on ACL changes applies only in `static` mode. In `operator` mode, changes go through reloads.
- The chart creates the API token Secret and the operator references it.
- A NetworkPolicy lets the operator reach port 6060.

## Implementation

- **Crates:**
  - `kube` (runtime, derive) and `k8s-openapi`;
  - `tokio`, `reqwest` (rustls);
  - `schemars` for resource schemas;
  - `toml`, `sha2`, and a random-number generator for generated passwords.
- **Location:** a separate crate or repo, `rmqtt-operator`, outside the broker workspace so the Kubernetes dependencies stay out of it. It depends on published crates only.
- **Packaging:** its own Helm chart (resource definitions, RBAC, Deployment), or a subchart of `charts/rmqtt`.
  - Two replicas with leader election.
  - RBAC limited to Secrets and its own resources in the namespaces it watches. No access to pods is needed.

## Testing

- **Unit tests:** rule assembly (ordering, placeholders, duplicate usernames, identical output for identical inputs), checked against saved example files.
- **Integration tests (kind, real `rmqttd` pods):**
  1. Create a user; a client can connect.
  2. Change its permissions; publishing is denied within the timeout.
  3. Delete the user; new connections are refused.
  4. Restart a pod; it comes back with the current ACL.
  5. Push an invalid rule; the running config is unchanged.
- **Failure test:** keep one node unreachable; `Synced` stays false while the other nodes still update.

## Phases

1. Step 0 checks, and the chart's `acl.mode` switch.
2. `RmqttUser` and `RmqttCluster`, with presets and default deny.
3. `RmqttAcl` with priorities, and generated passwords.
4. Hardening: metrics, Events, docs, publishing the operator's chart.
5. Later: the operator manages the StatefulSet, detects split-brain, and orchestrates scaling. Possibly an upstream PR adding hashed passwords to `rmqtt-acl`.

## Open decisions

- **Namespaces:** may users reference a cluster in another namespace? Common for a shared broker, but it is a security question.
- **Location:** a new repo, or a directory next to `charts/` in this one?
- **API group / domain name** for the resources.
