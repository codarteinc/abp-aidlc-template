using System;
using System.Threading.Tasks;
using Microsoft.AspNetCore.Http;
using Microsoft.Extensions.Configuration;

namespace ${PROJECT_NAME}.Middleware;

/// <summary>
/// Audit finding F-012 — emits Content-Security-Policy headers on every
/// host response. Defaults to Content-Security-Policy-Report-Only mode
/// (operator flips to enforce via <c>App:Csp:Mode=enforce</c> after the
/// 7-14 day soak documented in CLAUDE.md "CSP defaults to Report-Only").
///
/// <para>
/// The policy is built once in the constructor (singleton-friendly with
/// the conventional middleware shape) and emitted as-is per request. It
/// covers same-origin defaults for every fetch directive, allows
/// <c>data:</c> and <c>https:</c> image sources for any embedded
/// avatar/picture URLs, and permits <c>'unsafe-inline'</c> on
/// <c>style-src</c> as a deliberate compromise for Swagger UI and ABP's
/// MVC UI (both inject inline styles). <c>script-src</c> intentionally
/// stays <c>'self'</c> — no <c>'unsafe-inline'</c>, no
/// <c>'unsafe-eval'</c> — which is the load-bearing XSS guard.
/// </para>
///
/// <para>
/// Belt-and-braces: also sets <c>X-Frame-Options: DENY</c>. ABP's
/// <c>UseAbpSecurityHeaders</c> sets a SAMEORIGIN default; we tighten to
/// DENY because the SPA is not designed to be iframed anywhere.
/// </para>
///
/// <para>
/// Operator rollback: setting <c>App:Csp:Mode=disabled</c> short-circuits
/// the middleware (no CSP header AND no X-Frame-Options header emitted).
/// Documented as the safe escape hatch when a regression in the policy
/// itself blocks traffic faster than the operator can fix it.
/// </para>
/// </summary>
public class ContentSecurityPolicyMiddleware
{
    private readonly RequestDelegate _next;
    private readonly string _policy;
    private readonly bool _reportOnly;
    private readonly bool _disabled;

    public ContentSecurityPolicyMiddleware(RequestDelegate next, IConfiguration config)
    {
        _next = next;

        var mode = config["App:Csp:Mode"];
        // "disabled" short-circuits the middleware (no header emitted at all).
        // Documented operator rollback path — see CLAUDE.md template.
        _disabled = string.Equals(mode, "disabled", StringComparison.OrdinalIgnoreCase);
        // Default to report-only when the key is unset OR malformed.
        // "enforce" is the only value that flips to the strict header.
        _reportOnly = !string.Equals(mode, "enforce", StringComparison.OrdinalIgnoreCase);

        var reportUri = config["App:Csp:ReportUri"];
        var reportClause = string.IsNullOrWhiteSpace(reportUri)
            ? string.Empty
            : $"; report-uri {reportUri}";

        _policy =
            "default-src 'self'; "
            + "img-src 'self' data: https:; "
            + "style-src 'self' 'unsafe-inline'; "
            + "script-src 'self'; "
            + "connect-src 'self'; "
            + "frame-ancestors 'none'; "
            + "base-uri 'self'; "
            + "form-action 'self'"
            + reportClause;
    }

    public async Task InvokeAsync(HttpContext ctx)
    {
        if (_disabled)
        {
            await _next(ctx);
            return;
        }

        var headerName = _reportOnly
            ? "Content-Security-Policy-Report-Only"
            : "Content-Security-Policy";
        ctx.Response.Headers[headerName] = _policy;
        // Tighten X-Frame-Options past ABP's SAMEORIGIN default. The SPA
        // is not designed to be iframed — DENY closes clickjacking even
        // for same-origin embeds.
        ctx.Response.Headers["X-Frame-Options"] = "DENY";
        await _next(ctx);
    }
}
