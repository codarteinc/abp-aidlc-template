# Observability — ${PROJECT_NAME}

Operator-facing reference for the F-021 + F-039 observability stack
this scaffold ships with. Covers operational HTTP endpoints, custom
OpenTelemetry meter conventions, OTLP env-var wiring, and Sentry SPA
wiring.

## Operational endpoints

Audit findings F-021 + F-039 — operational HTTP surface for k8s probes,
Prometheus scrapes, and OTLP trace export.

- `/health-live` — process liveness probe. Anonymous, no DB, status 200
  if Kestrel can route a request. K8s liveness probe target. Body is
  empty by design (no fingerprint).
- `/health-ready` — readiness probe with database connectivity check.
  Auth-gated by the `HealthChecksPolicy` (requires `admin` OR
  `health-monitor` role). K8s readiness probe target — operator
  configures the probe with a service-account token tied to the
  `health-monitor` role (seeded by
  `${PROJECT_NAME}HealthMonitorRoleSeedContributor`; binding to specific
  service accounts is an operator concern). Body is plain text:
  `healthy` (200) or `unhealthy` (503). The wrapped exception, if any,
  is logged to `Logs/log-{date}.txt` — never the response body
  (audit finding F-038).
- `/metrics` — Prometheus scrape endpoint emitting AspNetCore
  instrumentation metrics + every `${PROJECT_NAME}.*` custom meter
  (see "OTel custom Meter naming" below). Same auth as
  `/health-ready` by default. Operators with network-level controls
  (k8s NetworkPolicy, IP allowlist at the LB) can override via
  `App:Metrics:Auth=false` in `appsettings.json`.

OTLP traces export to `$OTEL_EXPORTER_OTLP_ENDPOINT` when the env var
is set; no-op when unset (no app config change needed). Optional
companions: `OTEL_SERVICE_NAME` (defaults to
`${PROJECT_NAME_LOWER}-api`), `OTEL_RESOURCE_ATTRIBUTES` (e.g.,
`deployment.environment=staging,service.namespace=${PROJECT_NAME_LOWER}`).

## OTel custom Meter naming convention

Every custom `System.Diagnostics.Metrics.Meter` instantiated in this
codebase uses the prefix `${PROJECT_NAME}.<Feature>` (PascalCase,
dot-prefixed) — e.g., `new Meter("${PROJECT_NAME}.PictureUpload")`.

- **Meter names**: `${PROJECT_NAME}.<Feature>` (PascalCase,
  dot-prefixed).
- **Instrument names**: snake_case + unit suffix
  (`feature_event_total`, `feature_duration_ms`).
- **Prometheus scrape view**: the OTel Prometheus exporter auto-
  translates the meter dot-prefix to underscore:
  `${PROJECT_NAME_LOWER}_feature_event_total{...}`.
- **NEVER carry PII** (filenames, user ids, raw user input) in metric
  tags — only finite-cardinality dimensions like `reason`.

The host module's OTel wiring subscribes to the wildcard
`AddMeter("${PROJECT_NAME}.*")` so every meter following this naming
convention is auto-discovered. Adding a new meter requires NO host-
module change.

## Operator runbook

### Wire a real OTLP collector

OTLP traces export to `$OTEL_EXPORTER_OTLP_ENDPOINT` when set; the
exporter no-ops cleanly when unset (no config change needed for dev
boxes that don't run a collector).

```bash
# gRPC (default protocol)
export OTEL_EXPORTER_OTLP_ENDPOINT=http://collector.example:4317
# HTTP
export OTEL_EXPORTER_OTLP_ENDPOINT=http://collector.example:4318/v1/traces
export OTEL_EXPORTER_OTLP_PROTOCOL=http/protobuf
```

Optional resource attributes for cross-environment correlation:

```bash
export OTEL_SERVICE_NAME=${PROJECT_NAME_LOWER}-api
export OTEL_RESOURCE_ATTRIBUTES="deployment.environment=staging,service.namespace=${PROJECT_NAME_LOWER}"
```

### Wire Grafana to scrape `/metrics`

The Prometheus scrape endpoint is auth-gated by the
`HealthChecksPolicy` (requires `admin` OR `health-monitor` role).
Operators have two paths:

1. **Service-account token** (recommended): create a user, assign the
   `health-monitor` role (seeded by
   `${PROJECT_NAME}HealthMonitorRoleSeedContributor`), and bind a
   long-lived bearer token. Grafana's Prometheus data-source carries
   `Authorization: Bearer <token>` per scrape.
2. **Network-level allowlist**: set `App:Metrics:Auth=false` in
   `appsettings.json` (or the env-var form
   `App__Metrics__Auth=false`) AND restrict ingress to the scrape
   endpoint with a k8s NetworkPolicy or LB IP allowlist. This is the
   path for in-cluster scrapes from a sidecar Prometheus.

The `/health-ready` endpoint uses the SAME policy and SAME role;
configure the k8s readiness probe with the same bearer token.

### Wire Sentry (SPA exception reporting)

Sentry is OFF by default. The committed
`angular/dynamic-env.json` ships `"dsn": "REPLACE_ME_AT_DEPLOY"` and
the SDK's `Sentry.init` is gated on the DSN being a real value —
empty / unset / `REPLACE_ME_AT_DEPLOY` means **no network egress**.

To enable:

1. **Dev**: edit `angular/dynamic-env.json` directly with the real DSN
   (do NOT commit). Tracked file should keep the `REPLACE_ME_AT_DEPLOY`
   sentinel.
2. **Container deploy**: bind-mount `dynamic-env.json` from the host
   filesystem (or `kubectl create configmap`). The
   `angular/dynamic-env.json.template` ships placeholders for an
   entrypoint script (operator-managed) to render via `envsubst`:
   ```bash
   envsubst < /usr/share/nginx/html/dynamic-env.json.template \
          > /usr/share/nginx/html/dynamic-env.json
   ```
   with the env vars `APP_SENTRY_DSN`, `APP_SENTRY_ENVIRONMENT`,
   `APP_SENTRY_RELEASE` (etc.) set at container start.

Dashboard URL: operator-managed (per Sentry org). Note Sentry's
free-tier event quota — the bundled HTTP interceptor only reports 5xx
(client/4xx errors stay client-side).

### `/health-ready` probe token binding (k8s)

```yaml
readinessProbe:
  httpGet:
    path: /health-ready
    port: 80
    httpHeaders:
      - name: Authorization
        value: "Bearer <service-account-token>"
  initialDelaySeconds: 10
  periodSeconds: 30
```

The bearer token must be issued to a user in the `health-monitor`
role; see "Wire Grafana to scrape `/metrics`" above for the role
binding pattern.

## Post-scaffold SPA wiring (one-time, manual)

After the scaffold completes, two small edits to
`angular/src/app/app.config.ts` are required to wire the Sentry
ErrorHandler + HTTP interceptor into Angular's DI:

```ts
import { HTTP_INTERCEPTORS } from '@angular/common/http';
import { SentryErrorHandlerProvider } from './error-reporting/error-reporting.module';
import { ServerErrorReportingInterceptor } from './error-reporting/server-error-reporting.interceptor';

export const appConfig: ApplicationConfig = {
  providers: [
    // ...existing providers...
    SentryErrorHandlerProvider,
    {
      provide: HTTP_INTERCEPTORS,
      useClass: ServerErrorReportingInterceptor,
      multi: true,
    },
  ],
};
```

The scaffold ships `main.ts` already wired to call
`loadRuntimeErrorReportingConfig` + `initErrorReporting` BEFORE
`bootstrapApplication(...)` — no edit needed there. (A future
unit-11 polish pass can splice the `app.config.ts` providers
automatically via a marker block.)

## Rollback

Removing the `AddOpenTelemetry()` registration in
`${PROJECT_NAME}HttpApiHostModule.ConfigureServices` reverts the app
to vanilla ABP behavior (no metrics, no traces). The `/metrics` and
`/health-*` endpoints disappear, the Serilog `[trace=... span=...]`
placeholders go empty (the bootstrap-logger still runs but
`Enrich.WithSpan()` has no active OTel ActivitySource to read from).

No DB migration is required for either direction.
