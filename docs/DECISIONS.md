# Decisions and trade-offs

The choices I made, what else I considered, and what I'd revisit.

## Helm chart

### Redis is not a sub-chart
I considered the Bitnami chart as a dependency, assuming a Redis that already exists, and writing my own StatefulSet. I went with an existing Redis. It has a different lifecycle from a stateless API (failover, persistence, upgrades), and I don't want every app upgrade touching the cache. A dependency would also mean `helm dependency build` before `helm lint` works. The chart README shows the Bitnami command for local use. If someone wants a one-command dev setup later, add the dependency behind `redis.enabled`.

### The Secret can be created by the chart or supplied from outside
Options were rendering it from values, Sealed Secrets, External Secrets with AWS Secrets Manager, or Vault. The chart supports both styles through `secret.create` and `secret.existingSecret`. Dev and staging render it from values (the password comes in with `--set-file`). Production uses External Secrets. With a value-rendered Secret the password ends up in Helm's release history and is readable by anyone who can `get secret`. The cost is that production depends on External Secrets being installed. The `SecretStore` and `ExternalSecret` live in the production overlay. I used a namespaced `SecretStore` rather than a `ClusterSecretStore` so that only this namespace can read through it.

### The Secret outlives the ExternalSecret (`creationPolicy: Orphan`)
External Secrets defaults to `creationPolicy: Owner`, which puts an ownerReference on the Secret, so Kubernetes garbage-collects it as soon as the `ExternalSecret` is deleted. That happens more easily than it sounds: a pruning deploy after someone renames or moves the file, or External Secrets being uninstalled or reinstalled together with its CRDs, which deletes every `ExternalSecret` in the cluster. Running pods wouldn't notice, since the password is already in their environment. But the next pod to start, from an HPA scale-out, a node drain or a rollout, fails with `CreateContainerConfigError`, so the outage arrives exactly when we need capacity.

With `Orphan`, External Secrets still creates the Secret and keeps it in sync on every refresh, but the Secret's lifetime isn't tied to the `ExternalSecret`. The cost is a manual `kubectl delete secret data-sync-redis` when the service is retired, which is a small price for a credential every new pod needs.

`deletionPolicy: Retain` covers the other direction. If the AWS secret is deleted or can't be read, the last good copy stays in the cluster instead of being removed. The two settings together mean neither side disappearing can take the Secret with it.

### Rolling pods when config or secrets change
I looked at checksum annotations, the Reloader controller, kustomize's hashed `secretGenerator` names, and manual restarts. ConfigMap and chart-managed Secret changes use the normal `checksum/*` annotation. For the production Secret, which Helm doesn't own, the overlay carries the `SECRET_CHECKSUM` annotation the brief asks for, written by `scripts/secret-checksum.sh`. I prefer this to Reloader because the change is visible in git and goes through the usual rollout settings. The downside is that someone has to run it. If rotations get frequent, switch to Reloader.

### Why the secret rollout isn't automatic
External Secrets keeps the `data-sync-redis` Secret in sync on its own (every hour, or straight away with a forced sync). Pods don't pick that up: the password reaches them as an environment variable, which is fixed when the container starts. Something has to restart them, and in this repo that's a person running `make secret-checksum` and applying the overlay.

I left it manual on purpose. The rotation happens every 90 days, so a manual step costs little. Each restart is a reviewed one-line commit, which records when the password changed. The rollout also waits until the cluster actually holds the new password. A fully automatic restart could fire while Redis still accepts only the old password, and it would then take every pod down in turn. The weak point is that someone has to remember, so the 90-day reminder matters.

Ways to automate it, roughly in the order I'd adopt them:

- **Event-driven pipeline.** An EventBridge rule on the Secrets Manager rotation events (`RotationSucceeded`, or `PutSecretValue` from CloudTrail) starts a CI job. The job runs `scripts/secret-checksum.sh` and opens a pull request, and Argo CD or the CD pipeline applies it after the merge. The rotation keeps its review and git record without anyone having to remember. The CI role only needs `ListSecretVersionIds` and access to the cluster, never the password. This is the one I'd pick once Argo CD is in place.
- **Reloader.** The stakater controller watches the Secret and does a rolling restart as soon as External Secrets changes it. It's the least work, but the restart isn't in git, and it fires on any change to the Secret, including a mistaken one.
- **The app re-reads the password.** Mount the Secret as a file instead of an environment variable. The kubelet refreshes the file within about a minute, and the app reconnects with the new value when Redis rejects a login. There's no restart at all, but it needs a change in the app's Redis client. It's the best long-term option and the only one that isn't purely platform work.

### SECRET_CHECKSUM holds the AWS version ID, not a hash
The obvious value is a SHA-256 of the Secret's data, and that's what I'd avoid. A hash is derived from the password, so anyone who can read it can guess passwords offline until one matches. SHA-256 is fast and an unsalted hash makes a weak or reused password fall quickly; equal hashes would also show that two environments share a password. And it would be readable in more places than the Secret itself: git history forever, and the Deployment, ReplicaSet and Pod objects, which far more people can `get` than can read Secrets.

The value is now the `VersionId` of the secret's `AWSCURRENT` version in Secrets Manager. It's a random identifier that changes on every rotation, which is all the annotation needs to do, and it reveals nothing about the password. The script only needs `ListSecretVersionIds`, so whoever runs it, a person or a pipeline, never needs read access to the password at all. I also considered an HMAC with a key held in CI (safe, but one more secret to manage) and Reloader (nothing committed at all, but one more controller).

Reading the version from AWS rather than the cluster adds a race: the annotation could change before External Secrets has copied the new password into the cluster. New pods would then start with the old password, and since the annotation had already moved on, nothing would restart them again. The script closes that gap by forcing a sync and waiting for the `ExternalSecret` to report a successful refresh after that moment before it writes anything.

### Kustomize base is rendered Helm output
Instead of the `helmCharts` generator (needs `--enable-helm`) or a post-renderer, I commit the `helm template` output as the base. `kubectl apply -k` works without flags or Helm in the apply path, reviewers see the real manifests in PRs, and Argo CD or Flux can use it as is. A generated file can go stale, so CI runs `make check-render`.

### Hard zone spread
The overlay uses `DoNotSchedule` with `maxSkew: 1`. With at least 3 replicas on 3 AZs, losing a zone shouldn't take out most pods. If a zone runs short of capacity, pods stay Pending; switch to `ScheduleAnyway` if that matters more. Node-level spreading is only a soft anti-affinity in the chart. On EKS with Cluster Autoscaler, use one managed node group per AZ (a single multi-AZ group can't guarantee balance). Karpenter handles this natively.

### HPA stays on CPU
The brief asks for CPU, so that's what the chart has, plus scale-up/down behaviour and a 60% target in production. Better signals through KEDA are covered in `DESIGN.md`, but not built, since they need extra cluster components.

### PDB is off by default
`minAvailable: 1` with one replica makes node drains hang, so it's off in `values.yaml` and on in staging and production.

### ServiceMonitor is on by default
It fails to install without the Prometheus Operator CRDs, but the platform uses kube-prometheus-stack, so that's the sensible default. Use `--set serviceMonitor.enabled=false` on a bare cluster.

## Ansible role

### Python and packages
`python39`, `python39-pip`, `python39-devel` and `git` come from AppStream, with no extra repos. The brief says yum; on EL8 `yum` is just dnf, and ansible-core 2.17+ no longer ships a separate yum module, so the task uses `ansible.builtin.dnf`. Same packages, and it lints cleanly on current Ansible. The virtualenv comes from `python3.9 -m venv`, so the `virtualenv` package isn't needed. Python 3.9 is nearly end of life, so the interpreter is a variable (`data_sync_python_bin`) to make the upgrade easy.

### Where the password goes on a VM
Unit files are readable by anyone and show up in `systemctl show`, so `REDIS_PASSWORD` is written to a root-owned `0640` env file (task has `no_log`) from an Ansible Vault variable. The non-secret `APP_ENV`, `REDIS_HOST` and `LOG_LEVEL` stay in the unit, as the brief says.

### Reaching Redis and git from a VM
A VM can't resolve `*.svc.cluster.local`, so `group_vars/service.yml` points at `redis.data-sync.internal`, a Route 53 private record. It can point at ElastiCache, or at an internal load balancer in front of the in-cluster Redis while the EC2 hosts still exist. The role default is `127.0.0.1` so nothing reaches a real Redis by accident. The clone runs as the service user, so that user needs its own read-only deploy key (or an HTTPS token from Vault). `accept_newhostkey` trusts the git server on first contact but still fails if its key changes later.

### Tags
`install` covers packages, the user and directories. `deploy` covers the code, venv, config and service. The clone is under `deploy` because the dependencies come from the repo's `requirements.txt`, which means `--tags deploy` works alone on any host that's been installed.

### Rolling hosts
`serial: 1` with `max_fail_percentage: 0` stops a bad release after the first host. `flush_handlers` runs before the final "started" task so the unit is reloaded and restarted before we check state.

### Role name and ansible-lint
The team's `be-{service}` convention has a hyphen, which the `role-name` rule rejects. I skip that one rule instead of renaming the role. Everything else in the production profile passes.

## AWS instead of GCP

The brief allows AWS. Only the provider-specific parts changed; the chart and overlay are portable because they use standard labels like `topology.kubernetes.io/zone`.

- Pod identity: the app doesn't call AWS, so it has no IAM role (`serviceAccount.annotations` shows where the IRSA annotation would go). External Secrets gets its own IRSA role limited to this secret. I'd avoid the node role, because every pod on the node would inherit it.
- Secrets: External Secrets vs the Secrets Store CSI driver. External Secrets produces a normal Kubernetes Secret, which works with `secretKeyRef` and the checksum approach. The values also sit in etcd, so turn on EKS envelope encryption with KMS.
- Redis: in-cluster matches the brief's `REDIS_HOST`. ElastiCache would remove failover and patching work and supports two passwords per user, which helps rotation, but it costs more and in-transit encryption needs TLS in the app. I kept in-cluster as the default and noted the ElastiCache option in `values.production.yaml`.
- Images: ECR through the node role, no pull secrets. Cross-account ECR needs a repository policy.
- Inventory: `inventory.aws_ec2.yml` builds the `service` group from a `be_role` tag, so it can't drift from reality. It needs the `amazon.aws` collection and `boto3`, so `ansible.cfg` still points at the static example.
- Node capacity: Karpenter vs Cluster Autoscaler is discussed in `DESIGN.md`; neither is installed here.

## What's not done

- The image is a placeholder, and `app.main:app` and `requirements.txt` are assumptions.
- Nothing ran on a real cluster or VM. What I did run: `helm lint`, `helm template`, `kubectl kustomize`, `ansible-lint` (production profile), `--syntax-check`, and a local render of the Jinja templates. A Molecule test on a systemd-enabled Rocky 8 container would be the next step.
- No NetworkPolicy, Ingress or VPA recommendations.
- The ExternalSecret and SecretStore in `standard/data-sync/production/` assume External Secrets Operator 0.17+ is installed and that the IAM role and the AWS secret already exist (normally created by Terraform). I haven't validated them against a live ESO install.
- In dev and staging the chart still uses the standard Helm `checksum/secret` annotation, which is a SHA-256 of the rendered Secret and so carries the same offline-guessing risk described above. It's the common Helm idiom and those passwords are low value, but the same version-ID approach could replace it if staging moved to External Secrets too.
- `/health` doesn't check Redis. The brief says it returns `{"status":"ok"}`, so I left it. A readiness endpoint that pings Redis is recommended in `DESIGN.md`.
