# rmqtt Helm chart

Deploys the RMQTT broker as a StatefulSet Raft cluster (`rmqtt-cluster-raft`), with
username/password authentication and topic permissions handled by the `rmqtt-acl` plugin.

## Quick start

```sh
cp values-secrets.example.yaml values-secrets.yaml   # gitignored; edit the passwords
helm upgrade --install mqtt ./charts/rmqtt -n iot --create-namespace \
  -f my-values.yaml -f values-secrets.yaml
```

`my-values.yaml` declares the users and their permissions. It holds no passwords:

```yaml
acl:
  users:
    - username: alice
      permissions:
        - action: pubsub
          topics: ["devices/alice/#"]
    - username: dashboard
      superuser: true
```

## Users and passwords

rmqtt-acl only reads plaintext passwords from inside the `rules` array of
`rmqtt-acl.toml`. The broker has no native way to load them from a second file or env var:
an env override replaces the whole `rules` value, it does not merge. So the chart splits them
at deploy time:

| What | Where | Kubernetes object |
|------|-------|-------------------|
| Users, superuser flag, topic permissions, final rule | `values.yaml` (`acl.*`) | ConfigMap `<release>-rmqtt-acl` (a template with `@@ACL_PASSWORD:<key>@@` placeholders) |
| Passwords | `values-secrets.yaml` (`aclPasswords.<key>`) **or** `acl.existingSecret` | Secret `<release>-rmqtt-acl-passwords`, one key per user |

The `render-config` init container fills in the placeholders from the Secret (TOML-escaped)
and writes the final `rmqtt-acl.toml` to a memory-backed `emptyDir`. Only the init container
mounts the password Secret. If a password is missing, empty, or contains control characters,
the init container fails and the pod does not start.

- The key defaults to the username. If the username has characters that are not allowed in
  Secret keys (anything outside `[-._a-zA-Z0-9]`), set `passwordKey` explicitly.
- Rendering fails if a user has a `password` field in values, if an `acl.extraRules` entry
  contains "password", or if a user has no password and no `existingSecret` is set.
- Each user gets `["allow", {user, password, superuser}, "connect"]` followed by their
  permission rules. The last rule is `["deny", "all"]` (`acl.finalRule`), and every external
  listener has `allow_anonymous = false`.
- If you change ACL values or chart-managed passwords, the pods roll automatically
  (checksum annotations). If you change an **existing** Secret, the pods do not roll. Run
  `kubectl rollout restart statefulset/<name>`.

`existingSecret` example (e.g. from External Secrets or Sealed Secrets):

```sh
kubectl -n iot create secret generic mqtt-acl --from-literal=alice='...' --from-literal=dashboard='...'
kubectl -n iot create secret generic mqtt-api --from-literal=token='...'
helm upgrade --install mqtt ./charts/rmqtt -n iot -f my-values.yaml \
  --set acl.existingSecret=mqtt-acl --set httpApi.bearerToken.existingSecret=mqtt-api
```

## HTTP API token

`httpApi.bearerToken.enabled` is true by default. The token is passed to the broker as
`RMQTT_PLUGIN_RMQTT_HTTP_API_HTTP_BEARER_TOKEN` (the broker's native env override, taken
from the Secret). The readiness probe reads the same variable.

## Cluster

- Node id = pod ordinal + 1. The static `--node-grpc-addrs` / `--raft-peer-addrs` lists are
  generated from `replicaCount` using headless-service DNS. `replicaCount` is effectively
  fixed: changing it rolls every pod. Don't autoscale.
- `leader_id = 1`, `podManagementPolicy: OrderedReady`, and `publishNotReadyAddresses`
  on the headless service. On restart, a node joins the existing leader. Raft state is
  in memory, so no PVCs are used.
- `health.exit_on_node_unavailable = true`: a node that loses the cluster for about 20s exits,
  and the kubelet restarts it.
- PodDisruptionBudget `maxUnavailable: 1` and soft pod anti-affinity are enabled.

## Probes

- startup/liveness: TCP connect on 1883. This needs no credentials.
- readiness: `wget` to `/api/v1/health/check/<own id>` inside the pod. This returns 503 until
  the node's raft is running with a leader. It uses exec rather than `httpGet` because the node
  id differs per pod and the bearer token lives in a Secret. The id-less endpoint is not used
  because it queries every node.

## Networking

- Client Service (`service.type`, ClusterIP by default): 1883 MQTT and 8080 WS. With
  `tls.existingSecret` (a `kubernetes.io/tls` Secret; `ca.crt` is needed for
  `tls.mutualTls`), it also serves 8883 MQTTS and 8443 WSS.
- API Service: 6060, ClusterIP.
- Headless Service: 5363 gRPC and 6003 raft.
- NetworkPolicy: 5363, 6003, and 11883 (anonymous internal listener) are open only to broker
  pods. 6060 is open to the release namespace plus `networkPolicy.apiFrom`. The MQTT ports
  are open to `networkPolicy.clientFrom` (default: anywhere).
- `broker.listeners.proxyProtocol: true` makes every external listener require a PROXY
  header. Only enable it if all client traffic goes through a proxy or load balancer that
  sends one.

## Image

The chart expects the layout of the upstream `Dockerfile.amd64`: Alpine/busybox and
`/app/rmqtt/rmqtt-bin/rmqttd`. The demo certs and `rmqtt.toml` baked into the image are
not used: the pod's working directory is `/etc/rmqtt`, which holds only the rendered config.
The container runs as UID 65534 with a read-only root filesystem.
