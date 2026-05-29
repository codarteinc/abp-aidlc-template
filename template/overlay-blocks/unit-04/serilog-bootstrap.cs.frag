        // Audit finding F-039 — Serilog enrichers for OTel trace correlation.
        //   .Enrich.FromLogContext()    — flows ambient LogContext properties.
        //   .Enrich.WithSpan()          — adds TraceId / SpanId from the
        //                                 OTel ActivitySource current activity
        //                                 (NuGet: Serilog.Enrichers.Span).
        //   .Enrich.WithProperty(...)   — stamps every log line with the
        //                                 logical service name (consumers
        //                                 like Loki / Elastic key on this).
        // The outputTemplate is extended with [trace={TraceId} span={SpanId}]
        // so operators can correlate Logs/log-{date}.txt lines with
        // OTLP-exported spans. Both this bootstrap logger AND the main
        // UseSerilog pipeline (NOTE below) carry the same enrichers + template;
        // appsettings.json's outputTemplate mirrors this string.
        Serilog.Log.Logger = new Serilog.LoggerConfiguration()
            .Enrich.FromLogContext()
            .Enrich.WithSpan()
            .Enrich.WithProperty("Application", "${PROJECT_NAME_LOWER}-api")
            .Destructure.ByTransformingWhere<Volo.Abp.Identity.IdentityUser>(
                t => typeof(Volo.Abp.Identity.IdentityUser).IsAssignableFrom(t),
                u => new { u.Id, NormalizedUserName = u.NormalizedUserName ?? "(unknown)" })
            .WriteTo.Async(c => c.File(
                path: "Logs/log-.txt",
                rollingInterval: Serilog.RollingInterval.Day,
                retainedFileCountLimit: 14,
                fileSizeLimitBytes: 10L * 1024 * 1024,
                rollOnFileSizeLimit: true,
                shared: false,
                outputTemplate: "[{Timestamp:yyyy-MM-dd HH:mm:ss.fff zzz}] [{Level:u3}] [{CorrelationId}] [trace={TraceId} span={SpanId}] {Message:lj} {Exception}{NewLine}"))
            .WriteTo.Async(c => c.Console())
            .CreateBootstrapLogger();

        // NOTE — main pipeline UseSerilog wiring (mirrors the bootstrap-logger
        // enrichers + output template above) is wired by the unit-05-owned
        // `fwd-headers` block which sits after builder construction. If you
        // remove or have not yet populated that block, mirror the bootstrap
        // enrichers on the host pipeline by adding:
        //
        //   builder.Host
        //       .UseAutofac()
        //       .UseSerilog((ctx, svc, lc) => lc
        //           .Enrich.FromLogContext()
        //           .Enrich.WithSpan()
        //           .Enrich.WithProperty("Application", "${PROJECT_NAME_LOWER}-api")
        //           .ReadFrom.Configuration(ctx.Configuration)
        //           .ReadFrom.Services(svc));
        //
        // without it the log lines won't carry [trace=... span=...] at runtime
        // (only the bootstrap-logger lines emitted BEFORE Build() will).
