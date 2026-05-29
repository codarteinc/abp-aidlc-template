import {
  HttpErrorResponse,
  HttpEvent,
  HttpHandler,
  HttpInterceptor,
  HttpRequest,
} from '@angular/common/http';
import { Injectable } from '@angular/core';
import { Observable, catchError, throwError } from 'rxjs';
import * as Sentry from '@sentry/angular';

/**
 * Reports HTTP 5xx responses to Sentry exactly once per request. 4xx is
 * intentionally NOT reported (client/auth errors are not the SPA's problem
 * and would burn the free-tier event quota fast).
 *
 * The request URL is attached as the `request_url` tag — finite cardinality
 * is acceptable because the app's API surface is small. The business error
 * code (`error.error?.error?.code`) is added as a `business_error_code` tag
 * when present, for triage.
 *
 * Registered via the `HTTP_INTERCEPTORS` DI multi-provider in
 * `app.config.ts` — same pattern as `OnboardingErrorInterceptorClass` so
 * `provideHttpClient(withInterceptorsFromDi(), ...)` (set up by
 * `provideAbpCore`) picks it up.
 *
 * Idempotency: each request hits the interceptor exactly once; if a
 * component subscribes to the same `HttpClient.get(...)` twice, two
 * requests happen and two reports happen — that's the desired behaviour
 * (each HTTP attempt is a distinct event).
 */
@Injectable({ providedIn: 'root' })
export class ServerErrorReportingInterceptor implements HttpInterceptor {
  intercept(
    req: HttpRequest<unknown>,
    next: HttpHandler,
  ): Observable<HttpEvent<unknown>> {
    return next.handle(req).pipe(
      catchError((err: unknown) => {
        if (
          err instanceof HttpErrorResponse &&
          err.status >= 500 &&
          err.status <= 599
        ) {
          const businessCode = (err.error as { error?: { code?: string } })
            ?.error?.code;
          // CodeRabbit LOW (interceptor PII hygiene) — strip the query
          // string before tagging Sentry. `err.url` can carry slugs, ids,
          // and ad-hoc filter params that turn into Sentry tag values;
          // tags are intentionally finite-cardinality and operator-
          // visible, so dropping the query keeps both the cardinality
          // and the PII surface bounded. Fragment is already stripped
          // by Angular's HttpClient pre-send.
          const safeUrl = err.url ? err.url.split('?')[0] : '';
          Sentry.captureException(err, {
            tags: {
              request_url: safeUrl,
              ...(businessCode ? { business_error_code: businessCode } : {}),
            },
            level: 'error',
          });
        }
        return throwError(() => err);
      }),
    );
  }
}
