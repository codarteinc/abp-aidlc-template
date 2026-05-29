// Audit finding F-007 — surface the Server header on every response
// suppression + clamp the max request body at Kestrel level. The
// ForwardedHeaders middleware itself is wired in the host module (see the
// `fwd-headers` block in ${PROJECT_NAME}HttpApiHostModule.cs). This block
// only tightens the Kestrel-level knobs (Server header off, sensible
// MaxRequestBodySize default) at builder time so they apply BEFORE any
// app code runs.
builder.WebHost.ConfigureKestrel(o =>
{
    o.AddServerHeader = false;
});
