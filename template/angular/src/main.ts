import { provideZoneChangeDetection } from '@angular/core';
import { bootstrapApplication } from '@angular/platform-browser';
import { appConfig } from './app/app.config';
import { AppComponent } from './app/app.component';
import {
  initErrorReporting,
  loadRuntimeErrorReportingConfig,
} from './app/error-reporting/error-reporting.module';

// Initialize Sentry BEFORE Angular bootstraps so bootstrap errors are
// captured. The remote-config fetch failing is non-fatal —
// `initErrorReporting(undefined)` is a no-op. We deliberately fetch
// `/getEnvConfig` here (the same endpoint ABP's `remoteEnv` reads) instead
// of relying on `provideAppInitializer`, because ABP's environment merge
// runs in an APP_INITIALIZER AFTER bootstrap — too late to install the
// `ErrorHandler` for bootstrap-time crashes.
async function main(): Promise<void> {
  const config = await loadRuntimeErrorReportingConfig();
  initErrorReporting(config);

  await bootstrapApplication(AppComponent, {
    ...appConfig,
    providers: [provideZoneChangeDetection(), ...appConfig.providers],
  });
}

main().catch(err => console.error(err));
