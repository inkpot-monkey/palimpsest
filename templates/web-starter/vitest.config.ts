/// <reference types="vitest" />
import { getViteConfig } from 'astro/config';
import { configDefaults } from 'vitest/config';

// Reuse Astro's Vite resolution (the `@/*` alias, plugins) so unit tests import
// exactly what the site does. `happy-dom` is the DOM env; Playwright's `e2e/`
// specs and Nix/direnv trees are excluded from the unit run.
export default getViteConfig({
	test: {
		environment: 'happy-dom',
		exclude: [...configDefaults.exclude, '.direnv/**', 'e2e/**'],
	},
	// eslint-disable-next-line @typescript-eslint/no-explicit-any -- Astro's
	// getViteConfig return type doesn't line up with Vitest's UserConfig yet.
}) as any;
