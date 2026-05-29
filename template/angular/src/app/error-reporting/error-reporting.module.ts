import { ErrorHandler } from '@angular/core';
import * as Sentry from '@sentry/angular';

/**
 * Provider-facade for SPA error reporting. The rest of the app only touches
 * Angular's `ErrorHandler` contract; swapping providers
 * (Sentry / App Insights / Bugsnag) is contained to THIS folder.
 *
 * Init lifecycle:
 * - `loadRuntimeErrorReportingConfig()` is called from `main.ts` BEFORE
 *   `bootstrapApplication(...)` so the SDK is installed in time to capture
 *   bootstrap errors. It performs a single `fetch('/getEnvConfig')` — the
 *   same URL ABP's `remoteEnv` reads AFTER bootstrap (see `nginx.conf`
 *   location `/getEnvConfig`).
 * - `SentryErrorHandlerProvider` is registered in `app.config.ts`'s
 *   providers list so Sentry's wrapper replaces Angular's default
 *   `ErrorHandler`.
 *
 * DSN-unset contract (verified by tests):
 *   absent key                      → SDK no-op (no `init` call)
 *   empty / whitespace-only string  → SDK no-op
 *   `REPLACE_ME_AT_DEPLOY` literal  → SDK no-op (the committed placeholder)
 * Treat any non-empty trimmed DSN that does NOT match the placeholder as
 * "configured".
 *
 * PII strip: Sentry default integrations attach `event.user.email`,
 * `event.user.username`, `event.user.ip_address` when an Angular caller
 * has called `Sentry.setUser(...)` — the project hasn't, but
 * defense-in-depth strips them anyway. `sentryBeforeSend` is exported so
 * Vitest can call it directly.
 */

const PLACEHOLDER_DSN = 'REPLACE_ME_AT_DEPLOY';

export interface ErrorReportingRuntimeConfig {
  readonly dsn?: string | null;
  readonly environment?: string;
  readonly release?: string | null;
  readonly tracesSampleRate?: number;
}

export function isDsnConfigured(dsn: string | undefined | null): boolean {
  if (dsn === undefined || dsn === null) {
    return false;
  }
  const trimmed = dsn.trim();
  if (trimmed.length === 0) {
    return false;
  }
  if (trimmed === PLACEHOLDER_DSN) {
    return false;
  }
  return true;
}

/**
 * Exposed for Vitest. Strips PII (`email`, `username`, `ip_address`) from
 * outgoing events; keeps `event.user.id` because it isn't PII under this
 * project's strip list.
 */
export function sentryBeforeSend(
  event: Sentry.ErrorEvent,
): Sentry.ErrorEvent | null {
  if (event.user) {
    delete event.user.email;
    delete event.user.username;
    delete event.user.ip_address;
  }
  return event;
}

/**
 * Type-guard for the runtime `errorReporting` slice. Rejects any shape
 * where `dsn` / `environment` / `release` aren't strings, or
 * `tracesSampleRate` isn't a number — CodeRabbit MEDIUM #4 caught a
 * crash path where a malformed deploy-time `{ "dsn": 123 }` would make
 * `isDsnConfigured()` call `.trim()` on a number and abort SPA
 * bootstrap. Treat any mismatch as "not configured" (no-op).
 */
function isValidRuntimeConfig(
  candidate: unknown,
): candidate is ErrorReportingRuntimeConfig {
  if (candidate === null || typeof candidate !== 'object') {
    return false;
  }
  const obj = candidate as Record<string, unknown>;
  // dsn — optional, but if present MUST be a string or null.
  if (
    obj.dsn !== undefined &&
    obj.dsn !== null &&
    typeof obj.dsn !== 'string'
  ) {
    return false;
  }
  // environment — optional; MUST be a string when present.
  if (obj.environment !== undefined && typeof obj.environment !== 'string') {
    return false;
  }
  // release — optional, MAY be null.
  if (
    obj.release !== undefined &&
    obj.release !== null &&
    typeof obj.release !== 'string'
  ) {
    return false;
  }
  // tracesSampleRate — optional; MUST be a finite number when present.
  if (
    obj.tracesSampleRate !== undefined &&
    (typeof obj.tracesSampleRate !== 'number' ||
      !Number.isFinite(obj.tracesSampleRate))
  ) {
    return false;
  }
  return true;
}

/**
 * Fetches `/getEnvConfig` (the same endpoint ABP's `remoteEnv` uses) and
 * returns just the `errorReporting` slice. Resolves to `undefined` if the
 * fetch fails, the body isn't JSON, the slice is absent, or the slice's
 * field types don't match `ErrorReportingRuntimeConfig` (defensive against
 * a malformed deploy-time payload — caller treats `undefined` as
 * "not configured" / SDK no-op).
 */
export async function loadRuntimeErrorReportingConfig(
  fetchImpl: typeof fetch = fetch,
): Promise<ErrorReportingRuntimeConfig | undefined> {
  try {
    const resp = await fetchImpl('/getEnvConfig', { method: 'GET' });
    if (!resp.ok) {
      return undefined;
    }
    const body = (await resp.json()) as { errorReporting?: unknown };
    const candidate = body?.errorReporting;
    if (candidate === undefined || candidate === null) {
      return undefined;
    }
    if (!isValidRuntimeConfig(candidate)) {
      // Malformed deploy artifact — treat as "not configured" so the SPA
      // bootstrap continues cleanly. NO console warn: operator-facing
      // diagnostics happen at deploy-time validation, not at runtime.
      return undefined;
    }
    return candidate;
  } catch {
    return undefined;
  }
}

/**
 * Idempotent — calling this twice is harmless. `Sentry.init` is itself
 * idempotent, and the early return below skips the unconfigured case
 * cleanly without instantiating the SDK.
 */
export function initErrorReporting(
  config: ErrorReportingRuntimeConfig | undefined,
): void {
  if (!config || !isDsnConfigured(config.dsn)) {
    return;
  }
  Sentry.init({
    dsn: config.dsn ?? undefined,
    environment: config.environment ?? 'production',
    release: config.release ?? undefined,
    tracesSampleRate: config.tracesSampleRate ?? 0.1,
    replaysSessionSampleRate: 0,
    replaysOnErrorSampleRate: 0,
    integrations: [Sentry.browserTracingIntegration()],
    beforeSend: sentryBeforeSend,
  });
}

/**
 * Registered in `app.config.ts` as a plain provider — NOT inside
 * `provideAppInitializer` — because Angular's `ErrorHandler` is consumed
 * at injector construction (NgZone registers `onError` listeners against
 * the resolved ErrorHandler the moment the platform-browser zone starts).
 *
 * When `Sentry.init` was not called (DSN unset path), `createErrorHandler`
 * still returns a handler; the underlying `Sentry.captureException` is a
 * silent no-op without an active client, so no network egress happens.
 */
export const SentryErrorHandlerProvider = {
  provide: ErrorHandler,
  useValue: Sentry.createErrorHandler({ showDialog: false }),
};
