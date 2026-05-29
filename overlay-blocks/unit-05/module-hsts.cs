// Audit finding F-010 — HSTS + HTTPS-redirect first in the pipeline so
// plain-HTTP requests are redirected (307) before any other middleware
// mutates state. Gated on !IsDevelopment so localhost never gets
// HSTS-poisoned by an over-zealous max-age. ASP.NET Core's default
// UseHsts is 30 days, no includeSubDomains, no preload — that's the
// deliberate first-deploy ramp. Bump to 1 year after the 7-14 day soak
// (see CLAUDE.md); NEVER enable `preload` without explicit operator
// sign-off — the preload list is irrevocable in practice.
if (!context.GetEnvironment().IsDevelopment())
{
    app.UseHsts();
    app.UseHttpsRedirection();
}
// Audit finding F-007 — wire ForwardedHeaders so Caddy/nginx in front of
// Kestrel can hand us the real client scheme. Forwarded headers
// middleware is configured in ConfigureServices (env-gated KnownProxies
// list); this is just the wire-up.
app.UseForwardedHeaders();
