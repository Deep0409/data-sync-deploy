# data-sync chart

Deploys the data-sync FastAPI service (port 8080, `/health`, `/metrics`).

The chart creates a Deployment, a ClusterIP Service, an HPA, a ConfigMap, a Secret, a PodDisruptionBudget and a ServiceMonitor. The Secret holds `REDIS_PASSWORD`; the chart can create it or use one that already exists (`secret.existingSecret`).

## Requirements

- Helm 3.12+ and Kubernetes 1.27+ (EKS or any other cluster).
- The Prometheus Operator CRDs (kube-prometheus-stack) for the ServiceMonitor. Without them, add `--set serviceMonitor.enabled=false`.
- A Redis to talk to. Redis is not a dependency of this chart; see "Local Redis" below.

## Values

Pass `values.yaml` first and the environment file second. Later files win, and `--set` wins over both.

| | default | staging | production |
| --- | --- | --- | --- |
| replicas | 1 | 2 | HPA, 3 to 20 (CPU 60%) |
| `LOG_LEVEL` | DEBUG | INFO | INFO |
| `REDIS_HOST` | `redis-master` | `redis-master.data-sync-staging.svc.cluster.local` | `redis-master.data-sync.svc.cluster.local` |
| resources | 250m / 256Mi up to 1 CPU / 512Mi | same as default | 2 CPU / 2Gi, requests = limits |
| PDB | off | on | on |
| Secret | chart creates it (dev password) | chart creates it, password passed at deploy | external (`data-sync-redis`) |

The PDB is off by default because `minAvailable: 1` with a single replica blocks node drains.

## Checking the chart locally

No cluster is needed:

```bash
cd helm/charts/data-sync
helm lint . -f values.yaml -f values.staging.yaml
helm lint . -f values.yaml -f values.production.yaml
helm template data-sync . -n data-sync-staging -f values.yaml -f values.staging.yaml
helm template data-sync . -n data-sync -f values.yaml -f values.production.yaml
```

From the repo root, `make lint template` does the same for all three configurations.

## Local Redis

```bash
helm repo add bitnami https://charts.bitnami.com/bitnami
helm upgrade --install redis bitnami/redis -n data-sync --create-namespace \
  --set architecture=standalone --set auth.password=dev-only-change-me \
  --set fullnameOverride=redis          # gives a Service called redis-master
helm upgrade --install data-sync helm/charts/data-sync -n data-sync
kubectl -n data-sync port-forward svc/data-sync 8080:8080
```

The default image is a placeholder and doesn't exist. Point at a real one with `--set image.repository=... --set image.tag=...`. On EKS, nodes pull same-account ECR images through the node role, so no pull secret is needed.

## Staging

```bash
helm upgrade --install data-sync helm/charts/data-sync \
  --namespace data-sync-staging --create-namespace \
  -f helm/charts/data-sync/values.yaml \
  -f helm/charts/data-sync/values.staging.yaml \
  --set-file secret.redisPassword=./redis-password.txt \
  --atomic --timeout 5m

helm -n data-sync-staging status data-sync
helm -n data-sync-staging rollback data-sync
```

`--atomic` rolls the release back on its own if the new pods never become ready.

## Production

The chart doesn't create the Secret in production. `data-sync-redis` (key `REDIS_PASSWORD`) is created by External Secrets Operator from the AWS Secrets Manager secret `brightedge/production/data-sync/redis`, using the manifests in `standard/data-sync/production/`:

- `secret-store.yaml`: a ServiceAccount with an IRSA role that can read only this secret, and a `SecretStore` pointing at Secrets Manager.
- `external-secret.yaml`: the `ExternalSecret` that writes `data-sync-redis`.

Prerequisites, normally handled by Terraform: ESO 0.17+ installed in the cluster, the IAM role `data-sync-secrets-reader`, and the AWS secret stored as `{"password": "..."}`.

The kustomize path applies these for you. For the plain Helm path, apply them first and check that the Secret exists:

```bash
kubectl create namespace data-sync --dry-run=client -o yaml | kubectl apply -f -
kubectl -n data-sync apply -f standard/data-sync/production/secret-store.yaml \
                           -f standard/data-sync/production/external-secret.yaml
kubectl -n data-sync get externalsecret data-sync-redis   # STATUS should be SecretSynced
kubectl -n data-sync get secret data-sync-redis
```

Then deploy with either of these, not both.

Plain Helm:

```bash
helm upgrade --install data-sync helm/charts/data-sync \
  --namespace data-sync --create-namespace \
  -f helm/charts/data-sync/values.yaml \
  -f helm/charts/data-sync/values.production.yaml \
  --atomic --timeout 10m
```

Kustomize overlay, which also applies the External Secrets manifests and adds zone spreading and the `SECRET_CHECKSUM` annotation:

```bash
make render             # refresh standard/data-sync/base/helm-output.yaml
make secret-checksum    # sync ESO, then SECRET_CHECKSUM = AWS secret version ID
kubectl apply -k standard/data-sync/production
kubectl -n data-sync rollout status deploy/data-sync --timeout=10m
```

To roll back the overlay: `kubectl -n data-sync rollout undo deploy/data-sync`, or revert the commit and apply again. Keep `images[].name` in the overlay equal to `image.repository`.

## Rotating the Redis password

The full procedure is in [`docs/DESIGN.md`](../../../docs/DESIGN.md#3-rotating-redis_password-without-downtime). In short: rotate the secret in AWS Secrets Manager, run `make secret-checksum`, commit and apply. The script forces External Secrets to sync, waits until it has, and only then writes the new version ID into the annotation. The changed annotation triggers a rolling restart that respects the PDB and `maxUnavailable: 0`.

The script needs `secretsmanager:ListSecretVersionIds` on the secret and permission to annotate and read the `ExternalSecret`. It never needs to read the password.

## Commonly changed values

| Key | Default | Notes |
| --- | --- | --- |
| `replicaCount` | `1` | ignored when `autoscaling.enabled` is true |
| `image.repository`, `image.tag` | placeholder, `appVersion` | |
| `config.*` | see `values.yaml` | `config.extra` adds more non-sensitive variables |
| `secret.create`, `secret.existingSecret`, `secret.redisPassword` | `true`, `""`, dev value | |
| `autoscaling.*` | off | `minReplicas`, `maxReplicas`, `targetCPUUtilizationPercentage`, `behavior` |
| `pdb.enabled`, `pdb.minAvailable` | `false`, `1` | |
| `serviceMonitor.*` | on, 30s | `labels.release` has to match Prometheus' `serviceMonitorSelector` |
| `nodeSelector`, `tolerations`, `affinity`, `topologySpreadConstraints`, `priorityClassName` | empty | scheduling hooks, see `docs/DESIGN.md` |
