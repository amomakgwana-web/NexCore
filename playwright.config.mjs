import { defineConfig } from '@playwright/test';

export default defineConfig({
  testDir: './tests',
  timeout: 45_000,
  retries: 1,
  reporter: [['list']],
  use: {
    headless: true,
    viewport: { width: 1440, height: 900 },
    // Sandbox/dev environments can point at a pre-installed Chromium.
    ...(process.env.PW_EXEC ? { launchOptions: { executablePath: process.env.PW_EXEC } } : {}),
  },
});
