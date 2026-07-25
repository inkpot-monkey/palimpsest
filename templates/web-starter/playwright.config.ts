import { execSync } from 'node:child_process';
import { defineConfig, devices } from '@playwright/test';

// NixOS: Playwright's bundled browsers don't run, so we drive the system
// Chromium the dev shell provides. Honour PLAYWRIGHT_CHROMIUM_EXECUTABLE_PATH
// (set by flake.nix), else resolve a chromium binary from PATH.
const resolveChromium = (): string | undefined => {
	if (process.env.PLAYWRIGHT_CHROMIUM_EXECUTABLE_PATH) {
		return process.env.PLAYWRIGHT_CHROMIUM_EXECUTABLE_PATH;
	}
	for (const bin of ['chromium', 'chromium-browser', 'google-chrome-stable', 'google-chrome']) {
		try {
			return execSync(`command -v ${bin}`, { encoding: 'utf8' }).trim();
		} catch {
			/* try the next candidate */
		}
	}
	return undefined;
};

const PORT = 4321;
const executablePath = resolveChromium();

// Chromium-only, two viewports (#102). Mobile-first: Mobile Chrome (Pixel 5)
// runs first, then Desktop Chrome 1920×1080. Add more projects per site if a
// flow needs them.
export default defineConfig({
	testDir: './e2e',
	timeout: 60_000,
	fullyParallel: true,
	forbidOnly: !!process.env.CI,
	retries: process.env.CI ? 2 : 0,
	workers: process.env.CI ? 1 : undefined,
	reporter: 'list',
	use: {
		baseURL: `http://localhost:${PORT}`,
		trace: 'on-first-retry',
		launchOptions: {
			executablePath,
			args: ['--no-sandbox'],
		},
	},
	projects: [
		{
			name: 'Mobile Chrome',
			use: { ...devices['Pixel 5'] },
		},
		{
			name: 'Desktop Chrome',
			use: { ...devices['Desktop Chrome'], viewport: { width: 1920, height: 1080 } },
		},
	],
	webServer: {
		command: 'pnpm dev',
		url: `http://localhost:${PORT}`,
		reuseExistingServer: !process.env.CI,
		timeout: 120_000,
	},
});
