# GCP (Cloud Run) deploy

This folder contains a **starter Terraform** setup to deploy SmartBuket Analytics to **Google Cloud Run**.

## What it creates

- Artifact Registry repo for container images
- Service account for Cloud Run services
- Cloud Run services:
  - `ingest-api`
  - `query-api`
  - `reco-api`
  - `processor` (worker + health endpoint)
  - `outbox-publisher` (worker + health endpoint)

- Cloud SQL (Postgres 16) + application DB/user
- Secret Manager secret `sb-postgres-dsn` and wiring to Cloud Run (`SB_POSTGRES_DSN`)

## What it assumes / does NOT create (yet)

 A managed RabbitMQ broker.
  - Recommended: create a Secret Manager secret (default id: `sb-rabbitmq-url`) and Cloud Run reads it.
  - Alternative: set `enable_rabbitmq_secret = false` and pass `SB_RABBITMQ_URL` via `env`.

If you disable Cloud SQL (`enable_cloudsql = false`), then you must provide `SB_POSTGRES_DSN` via `env`.

If you want, we can extend this to provision Cloud SQL (Postgres+PostGIS) and Secret Manager wiring.

## Quick start

1. Install prerequisites:
  - Terraform CLI
  - Google Cloud SDK (`gcloud`)
2. Authenticate:
  - `gcloud auth application-default login`
3. Build & push container images (example script):
  - `scripts/cloudrun-build-and-deploy.ps1 -ProjectId YOUR_PROJECT -Region us-central1 -Repo sb-analytics -Tag latest`
4. Create `terraform.tfvars` (start from `terraform.tfvars.example`):

```hcl
project_id   = "YOUR_PROJECT"
region       = "us-central1"
artifact_repo = "sb-analytics"

images = {
  ingest_api       = "us-central1-docker.pkg.dev/YOUR_PROJECT/sb-analytics/ingest-api:latest"
  query_api        = "us-central1-docker.pkg.dev/YOUR_PROJECT/sb-analytics/query-api:latest"
  reco_api         = "us-central1-docker.pkg.dev/YOUR_PROJECT/sb-analytics/reco-api:latest"
  processor        = "us-central1-docker.pkg.dev/YOUR_PROJECT/sb-analytics/processor:latest"
  outbox_publisher = "us-central1-docker.pkg.dev/YOUR_PROJECT/sb-analytics/outbox-publisher:latest"
}

env = {
  SB_POSTGRES_DSN = "postgresql+psycopg://USER:PASSWORD@HOST:5432/sb_analytics"
  SB_RABBITMQ_URL = "amqp://USER:PASSWORD@RABBITMQ_HOST:5672/"
}
```

  # Non-secret env vars only.
 }

enable_rabbitmq_secret = true
manage_rabbitmq_secret = false
rabbitmq_secret_id     = "sb-rabbitmq-url"
```bash
terraform init
terraform apply
```

### Nota sobre `terraform init`

Este módulo usa backend remoto GCS (ver `backend.tf`).

- Para **validar/formatear localmente** sin configurar backend (evita que se “quede colgado” esperando bucket/prefix):
  - `scripts/terraform-validate-local.ps1`
- Para **trabajar con estado remoto** localmente, inicializa con backend-config:
  - `terraform init -backend-config="bucket=TU_BUCKET" -backend-config="prefix=smartbuket-analytics"`

## CI/CD (Cloud Build)

Once the Terraform infra exists, you can build+push+deploy all services via Cloud Build:

- Config: `infra/gcp/cloudbuild/cloudbuild.yaml`
- Submit (PowerShell): `scripts/cloudbuild-submit.ps1 -ProjectId YOUR_PROJECT -Region us-central1 -Repo sb-analytics`

## Bootstrap 100% automático (Cloud Build + Terraform)

Pipeline que crea infraestructura + inicializa Postgres (PostGIS/tablas) + construye imágenes + deja Cloud Run listo:

- Config: `infra/gcp/cloudbuild/cloudbuild-bootstrap.yaml`
- Submit (PowerShell): `scripts/cloudbuild-bootstrap.ps1 -ProjectId YOUR_PROJECT -Region us-central1 -Repo sb-analytics -TfStateBucket YOUR_UNIQUE_BUCKET -RabbitmqSecretId sb-rabbitmq-url`

Notas:
- `_TF_STATE_BUCKET` debe ser un nombre globalmente único de bucket GCS.
- Crea el secreto `sb-rabbitmq-url` una sola vez (no se pasa por substitutions):
  - `gcloud secrets create sb-rabbitmq-url --replication-policy=automatic`
  - `gcloud secrets versions add sb-rabbitmq-url --data-file=PATH_AL_ARCHIVO_CON_URL`

## Notes

- For **staging/prod**, do **not** store secrets in tfvars; use Secret Manager.
- By default, Terraform deploys Cloud Run with **internal + load balancer ingress**.
  - The perimeter HTTPS LB (if `enable_perimeter=true`) exposes **only** `ingest-api` by default (see `public_service_names`).
  - Cloud Run IAM unauthenticated invoker is enabled for those public services when the perimeter is enabled (LB needs it).
  - Enforce auth via JWT at the application layer (`SB_AUTH_MODE=jwt`) and use Cloud Armor rate limiting / allowlists.

### Perímetro (HTTPS LB + Cloud Armor)

Variables principales:
- `enable_perimeter = true`
- `perimeter_service_name = "ingest-api"`
- `perimeter_domain = "api.tu-dominio.com"` (opcional; si no, queda HTTP por IP)
- `cloud_armor_enable = true`
- `cloud_armor_rate_limit_enabled = true`
- `cloud_armor_allow_ip_ranges = ["X.X.X.X/32", ...]` (opcional)

 Cloud SQL:
  - `cloudsql_enable_public_ip=true` is convenient for bootstrap.
  - For production: set `enable_private_networking=true` and `cloudsql_enable_public_ip=false`.
    - Note: initializing DB from Cloud Build with Private IP typically requires a **Private Pool** (VPC-connected) or running init from inside the VPC.

## Checklist final de producción

### Identidad y acceso

- Cloud Run:
  - Mantén `allow_unauthenticated = false`.
  - Deja `public_service_names = ["ingest-api"]` (o la mínima superficie que necesites).
- Autenticación:
  - Activa JWT en las APIs: `SB_AUTH_MODE=jwt` + `SB_JWKS_URL` + (`SB_JWT_ISSUER`, `SB_JWT_AUDIENCE`).
  - Si necesitas “ingest público” (LB), usa JWT obligatorio para evitar ingest anónimo.
- IAM:
  - Revisa `invoker_members` para permitir solo identidades del perímetro (si usas API Gateway/Apigee) o de servicios internos.

### Perímetro (recomendado)

- HTTPS:
  - Define `perimeter_domain` y apunta el DNS al `perimeter_ip`.
  - Deja `perimeter_enable_http_redirect=true`.
- Cloud Armor:
  - Activa `cloud_armor_enable=true`.
  - Ajusta rate limiting (`cloud_armor_rate_limit_*`) al volumen esperado.
  - Opcional: `cloud_armor_allow_ip_ranges` si el proveedor del SDK/ingest sale desde IPs fijas.

### Secretos

- Asegura que estos secretos existan y se roten:
  - `sb-rabbitmq-url`
  - `sb-postgres-dsn`
- No uses substitutions/CLI para credenciales en CI; Secret Manager como fuente única.

### Base de datos (Cloud SQL)

- Seguridad:
  - Producción: `enable_private_networking=true` y `cloudsql_enable_public_ip=false`.
  - Mantén `require_ssl=true` (ya está en el módulo).
- Resiliencia:
  - Backups habilitados (ya) y PITR habilitado (ya).
  - Define `cloudsql_deletion_protection=true` en prod.

### Red

- Cloud Run egress:
  - Si usas private networking, conserva `egress = PRIVATE_RANGES_ONLY`.
- Evita exponer Query/Reco/Workers al público; mantenlos internos.

### Observabilidad y operación

- Logging:
  - Centraliza logs en Cloud Logging; define retención y alertas.
- Alertas mínimas:
  - Errores 5xx (ingest/query/reco)
  - Latencia p95/p99 (ingest)
  - DLQ / retries altos (si aplica)
  - Conexiones/CPU/memoria de Cloud SQL
- Costos:
  - Ajusta `max_instance_count` en Cloud Run y el tier de Cloud SQL según carga real.

## Cloud Build security

Terraform creates two service accounts:
- `sb-cloudbuild-deploy`: minimal perms for build+push+deploy
- `sb-cloudbuild-bootstrap`: extra perms for the one-time bootstrap pipeline
