import { beforeEach, describe, expect, it, vi } from 'vitest';
import {
  HttpErrorResponse,
  HttpEvent,
  HttpHandlerFn,
  HttpRequest,
  HttpResponse,
} from '@angular/common/http';
import { TestBed } from '@angular/core/testing';
import { Observable, firstValueFrom, of, throwError } from 'rxjs';
import * as Sentry from '@sentry/angular';
import { ServerErrorReportingInterceptor } from './server-error-reporting.interceptor';

// `vi.mock(...)` is hoisted by Vitest to BEFORE all `import` statements
// in this module — placing it here visually under the imports is purely
// a readability choice. Keep the factory self-contained — outer bindings
// (including the imports above) are not resolved at hoist time. Inline
// `vi.fn()` calls in the factory satisfy this.
vi.mock('@sentry/angular', () => ({
  captureException: vi.fn(),
}));

describe('ServerErrorReportingInterceptor', () => {
  beforeEach(() => {
    vi.mocked(Sentry.captureException).mockClear();
    TestBed.configureTestingModule({ providers: [] });
  });

  function makeReq(): HttpRequest<unknown> {
    return new HttpRequest('GET', 'https://api.example/foo');
  }

  function run(next: HttpHandlerFn): Observable<HttpEvent<unknown>> {
    return TestBed.runInInjectionContext(() => {
      const interceptor = TestBed.inject(ServerErrorReportingInterceptor);
      return interceptor.intercept(makeReq(), {
        handle: (req: HttpRequest<unknown>) => next(req),
      });
    });
  }

  it('passes a 200 response through without capturing', async () => {
    const resp = new HttpResponse({ status: 200, body: { ok: true } });
    const next: HttpHandlerFn = () => of(resp);

    const out = await firstValueFrom(run(next));

    expect(out).toBe(resp);
    expect(Sentry.captureException).not.toHaveBeenCalled();
  });

  it('passes 400 / 401 / 403 / 404 through without capturing', async () => {
    for (const status of [400, 401, 403, 404]) {
      vi.mocked(Sentry.captureException).mockClear();
      const err = new HttpErrorResponse({
        status,
        url: 'https://api.example/foo',
      });
      const next: HttpHandlerFn = () => throwError(() => err);
      await expect(firstValueFrom(run(next))).rejects.toBe(err);
      expect(Sentry.captureException).not.toHaveBeenCalled();
    }
  });

  it('captures 500 once with request_url tag and re-throws', async () => {
    const err = new HttpErrorResponse({
      status: 500,
      url: 'https://api.example/foo',
    });
    const next: HttpHandlerFn = () => throwError(() => err);

    await expect(firstValueFrom(run(next))).rejects.toBe(err);

    expect(Sentry.captureException).toHaveBeenCalledTimes(1);
    const [capturedErr, ctx] = vi.mocked(Sentry.captureException).mock.calls[0];
    expect(capturedErr).toBe(err);
    expect(ctx).toMatchObject({
      tags: { request_url: 'https://api.example/foo' },
      level: 'error',
    });
  });

  it('captures 502', async () => {
    const err = new HttpErrorResponse({
      status: 502,
      url: 'https://api.example/foo',
    });
    const next: HttpHandlerFn = () => throwError(() => err);

    await expect(firstValueFrom(run(next))).rejects.toBe(err);
    expect(Sentry.captureException).toHaveBeenCalledTimes(1);
  });

  it('captures 503', async () => {
    const err = new HttpErrorResponse({
      status: 503,
      url: 'https://api.example/foo',
    });
    const next: HttpHandlerFn = () => throwError(() => err);

    await expect(firstValueFrom(run(next))).rejects.toBe(err);
    expect(Sentry.captureException).toHaveBeenCalledTimes(1);
  });

  it('attaches business_error_code tag when error body has error.code', async () => {
    const err = new HttpErrorResponse({
      status: 500,
      url: 'https://api.example/foo',
      error: { error: { code: '${PROJECT_NAME}:Whatever' } },
    });
    const next: HttpHandlerFn = () => throwError(() => err);

    await expect(firstValueFrom(run(next))).rejects.toBe(err);

    const [, ctx] = vi.mocked(Sentry.captureException).mock.calls[0];
    expect(ctx).toMatchObject({
      tags: {
        request_url: 'https://api.example/foo',
        business_error_code: '${PROJECT_NAME}:Whatever',
      },
    });
  });

  it('does NOT capture HttpErrorResponse with status 0 (network/CORS)', async () => {
    // status 0 is below the 500-599 range, so it should NOT be reported by
    // this interceptor. Sentry's global ErrorHandler still sees it via the
    // unhandled-rejection path if the caller doesn't catch it.
    const err = new HttpErrorResponse({ status: 0, url: 'https://api.example/foo' });
    const next: HttpHandlerFn = () => throwError(() => err);

    await expect(firstValueFrom(run(next))).rejects.toBe(err);
    expect(Sentry.captureException).not.toHaveBeenCalled();
  });

  // CodeRabbit LOW (interceptor PII hygiene) — `err.url` can carry slugs,
  // ids, and ad-hoc filter params that would otherwise blow up Sentry tag
  // cardinality and leak PII. The interceptor strips the query string
  // before tagging.
  it('strips the query string from request_url tag', async () => {
    const err = new HttpErrorResponse({
      status: 500,
      url: 'https://api.example/foo?slug=alice&token=secret',
    });
    const next: HttpHandlerFn = () => throwError(() => err);

    await expect(firstValueFrom(run(next))).rejects.toBe(err);

    expect(Sentry.captureException).toHaveBeenCalledTimes(1);
    const [, ctx] = vi.mocked(Sentry.captureException).mock.calls[0];
    const tag = (ctx as { tags?: { request_url?: string } })?.tags?.request_url;
    expect(tag).toBe('https://api.example/foo');
    expect(tag).not.toContain('?');
    expect(tag).not.toContain('slug=');
    expect(tag).not.toContain('secret');
  });

  it('handles err.url with no query string unchanged', async () => {
    const err = new HttpErrorResponse({
      status: 500,
      url: 'https://api.example/foo',
    });
    const next: HttpHandlerFn = () => throwError(() => err);

    await expect(firstValueFrom(run(next))).rejects.toBe(err);

    const [, ctx] = vi.mocked(Sentry.captureException).mock.calls[0];
    expect(
      (ctx as { tags?: { request_url?: string } })?.tags?.request_url,
    ).toBe('https://api.example/foo');
  });

  it('handles err.url being null (defensive default to empty string)', async () => {
    const err = new HttpErrorResponse({ status: 500, url: null });
    const next: HttpHandlerFn = () => throwError(() => err);

    await expect(firstValueFrom(run(next))).rejects.toBe(err);

    const [, ctx] = vi.mocked(Sentry.captureException).mock.calls[0];
    expect(
      (ctx as { tags?: { request_url?: string } })?.tags?.request_url,
    ).toBe('');
  });
});
