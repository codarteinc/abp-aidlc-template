// Audit finding F-012 — emit Content-Security-Policy on every response.
// Placed AFTER UseAbpSecurityHeaders so any header collision is decided
// by us (we own the policy contract). Defaults to
// Content-Security-Policy-Report-Only (operator flips to enforce via
// App:Csp:Mode=enforce after the 7-14 day soak documented in CLAUDE.md).
app.UseMiddleware<${PROJECT_NAME}.Middleware.ContentSecurityPolicyMiddleware>();
// F-010 — UseCookiePolicy applies CookiePolicyOptions
// (Secure=Always, HttpOnly=Always, MinimumSameSitePolicy=Lax) to every
// response cookie emitted downstream. Placed BEFORE UseAuthentication so
// the auth cookies ABP/OpenIddict emit get the Secure/HttpOnly/SameSite
// uplift.
app.UseCookiePolicy();
