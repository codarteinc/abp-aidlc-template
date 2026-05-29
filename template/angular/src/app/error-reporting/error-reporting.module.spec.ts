import { beforeEach, describe, expect, it, vi } from 'vitest';
import * as Sentry from '@sentry/angular';
import {
  ErrorReportingRuntimeConfig,
  initErrorReporting,
  isDsnConfigured,
  loadRuntimeErrorReportingConfig,
  sentryBeforeSend,
} from './error-reporting.module';

// `vi.mock(...)` is hoisted by Vitest to BEFORE all `import` statements
// in this module — placing it here visually under the imports is purely
// a readability choice. The factory MUST be self-contained (no closures
// over outer bindings) because at hoist time those bindings haven't
// resolved yet. Inline `vi.fn()` calls inside the factory satisfy this.
vi.mock('@sentry/angular', () => ({
  init: vi.fn(),
  createErrorHandler: vi.fn(() => ({ handleError: vi.fn() })),
  browserTracingIntegration: vi.fn(() => ({ name: 'BrowserTracing' })),
}));

describe('isDsnConfigured', () => {
  it('returns false for undefined', () => {
    expect(isDsnConfigured(undefined)).toBe(false);
  });

  it('returns false for null', () => {
    expect(isDsnConfigured(null)).toBe(false);
  });

  it('returns false for an empty string', () => {
    expect(isDsnConfigured('')).toBe(false);
  });

  it('returns false for whitespace-only strings', () => {
    expect(isDsnConfigured('   ')).toBe(false);
  });

  it('returns false for the REPLACE_ME_AT_DEPLOY placeholder', () => {
    expect(isDsnConfigured('REPLACE_ME_AT_DEPLOY')).toBe(false);
  });

  it('returns true for a real-looking DSN', () => {
    expect(isDsnConfigured('https://abc@o0.ingest.sentry.io/1')).toBe(true);
  });
});

describe('sentryBeforeSend', () => {
  it('strips email / username / ip_address from event.user while keeping id', () => {
    const event = {
      user: {
        id: 'keep-me',
        email: 'x@y.example',
        username: 'someone',
        ip_address: '1.2.3.4',
      },
    } as Sentry.ErrorEvent;

    const out = sentryBeforeSend(event);

    expect(out).not.toBeNull();
    expect(out!.user).toBeDefined();
    expect(out!.user!.id).toBe('keep-me');
    expect(out!.user!.email).toBeUndefined();
    expect(out!.user!.username).toBeUndefined();
    expect(out!.user!.ip_address).toBeUndefined();
  });

  it('leaves events without a user block untouched', () => {
    const event = { message: 'boom' } as Sentry.ErrorEvent;
    const out = sentryBeforeSend(event);
    expect(out).toBe(event);
  });
});

describe('initErrorReporting (no-op contract)', () => {
  beforeEach(() => {
    vi.mocked(Sentry.init).mockClear();
  });

  it('does NOT call Sentry.init when config is undefined', () => {
    initErrorReporting(undefined);
    expect(Sentry.init).not.toHaveBeenCalled();
  });

  it('does NOT call Sentry.init when DSN is empty string', () => {
    initErrorReporting({ dsn: '' });
    expect(Sentry.init).not.toHaveBeenCalled();
  });

  it('does NOT call Sentry.init when DSN is the REPLACE_ME placeholder', () => {
    initErrorReporting({ dsn: 'REPLACE_ME_AT_DEPLOY' });
    expect(Sentry.init).not.toHaveBeenCalled();
  });

  it('calls Sentry.init with the expected shape for a valid DSN', () => {
    const config: ErrorReportingRuntimeConfig = {
      dsn: 'https://abc@o0.ingest.sentry.io/1',
      environment: 'staging',
      release: 'v1.2.3',
      tracesSampleRate: 0.25,
    };

    initErrorReporting(config);

    expect(Sentry.init).toHaveBeenCalledTimes(1);
    const arg = vi.mocked(Sentry.init).mock.calls[0][0];
    expect(arg.dsn).toBe('https://abc@o0.ingest.sentry.io/1');
    expect(arg.environment).toBe('staging');
    expect(arg.release).toBe('v1.2.3');
    expect(arg.tracesSampleRate).toBe(0.25);
    expect(typeof arg.beforeSend).toBe('function');
  });

  it('defaults environment to "production" and tracesSampleRate to 0.1 when omitted', () => {
    initErrorReporting({ dsn: 'https://abc@o0.ingest.sentry.io/1' });
    const arg = vi.mocked(Sentry.init).mock.calls[0][0];
    expect(arg.environment).toBe('production');
    expect(arg.tracesSampleRate).toBe(0.1);
  });
});

describe('loadRuntimeErrorReportingConfig', () => {
  function makeFetchOk(body: unknown): typeof fetch {
    return vi.fn(async () => ({
      ok: true,
      status: 200,
      json: async () => body,
    })) as unknown as typeof fetch;
  }

  it('returns the errorReporting slice on 200 with valid JSON', async () => {
    const fetchImpl = makeFetchOk({
      errorReporting: { dsn: 'real-dsn', environment: 'prod' },
    });
    const out = await loadRuntimeErrorReportingConfig(fetchImpl);
    expect(out).toEqual({ dsn: 'real-dsn', environment: 'prod' });
  });

  it('returns undefined when the response body lacks errorReporting', async () => {
    const fetchImpl = makeFetchOk({ something: 'else' });
    const out = await loadRuntimeErrorReportingConfig(fetchImpl);
    expect(out).toBeUndefined();
  });

  it('returns undefined when JSON parsing throws (malformed body)', async () => {
    const fetchImpl = vi.fn(async () => ({
      ok: true,
      status: 200,
      json: async () => {
        throw new SyntaxError('Unexpected token');
      },
    })) as unknown as typeof fetch;
    const out = await loadRuntimeErrorReportingConfig(fetchImpl);
    expect(out).toBeUndefined();
  });

  it('returns undefined on 404', async () => {
    const fetchImpl = vi.fn(async () => ({
      ok: false,
      status: 404,
      json: async () => ({}),
    })) as unknown as typeof fetch;
    const out = await loadRuntimeErrorReportingConfig(fetchImpl);
    expect(out).toBeUndefined();
  });

  it('returns undefined on a network error (fetch rejects)', async () => {
    const fetchImpl = vi.fn(async () => {
      throw new TypeError('Failed to fetch');
    }) as unknown as typeof fetch;
    const out = await loadRuntimeErrorReportingConfig(fetchImpl);
    expect(out).toBeUndefined();
  });

  // CodeRabbit MEDIUM #4 — guard against a malformed deploy-time payload.
  // Pre-fix, `await resp.json() as ErrorReportingRuntimeConfig` was a
  // lying type assertion; a number / non-string `dsn` would later trip
  // `.trim()` on a non-string inside `isDsnConfigured` and abort SPA
  // bootstrap. The new shape validator returns `undefined` (= SDK no-op)
  // on any field-type mismatch.
  it('returns undefined when dsn is a non-string (number)', async () => {
    const fetchImpl = makeFetchOk({ errorReporting: { dsn: 123 } });
    const out = await loadRuntimeErrorReportingConfig(fetchImpl);
    expect(out).toBeUndefined();
  });

  it('returns undefined when dsn is a non-string (boolean)', async () => {
    const fetchImpl = makeFetchOk({ errorReporting: { dsn: true } });
    const out = await loadRuntimeErrorReportingConfig(fetchImpl);
    expect(out).toBeUndefined();
  });

  it('returns undefined when environment is a non-string', async () => {
    const fetchImpl = makeFetchOk({
      errorReporting: { dsn: 'real', environment: 42 },
    });
    const out = await loadRuntimeErrorReportingConfig(fetchImpl);
    expect(out).toBeUndefined();
  });

  it('returns undefined when release is a non-string non-null', async () => {
    const fetchImpl = makeFetchOk({
      errorReporting: { dsn: 'real', release: { tag: 'v1' } },
    });
    const out = await loadRuntimeErrorReportingConfig(fetchImpl);
    expect(out).toBeUndefined();
  });

  it('returns undefined when tracesSampleRate is not a finite number', async () => {
    const fetchImpl = makeFetchOk({
      errorReporting: { dsn: 'real', tracesSampleRate: 'fast' },
    });
    const out = await loadRuntimeErrorReportingConfig(fetchImpl);
    expect(out).toBeUndefined();
  });

  it('returns undefined when errorReporting is itself a non-object (string)', async () => {
    const fetchImpl = makeFetchOk({ errorReporting: 'malformed' });
    const out = await loadRuntimeErrorReportingConfig(fetchImpl);
    expect(out).toBeUndefined();
  });

  it('accepts a valid config where release is explicitly null', async () => {
    const fetchImpl = makeFetchOk({
      errorReporting: { dsn: 'real', release: null },
    });
    const out = await loadRuntimeErrorReportingConfig(fetchImpl);
    expect(out).toEqual({ dsn: 'real', release: null });
  });

  it('accepts a valid config where dsn is explicitly null', async () => {
    const fetchImpl = makeFetchOk({ errorReporting: { dsn: null } });
    const out = await loadRuntimeErrorReportingConfig(fetchImpl);
    expect(out).toEqual({ dsn: null });
  });
});
