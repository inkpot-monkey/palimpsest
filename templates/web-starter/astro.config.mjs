// @ts-check
import { defineConfig } from 'astro/config';

// Static-first — rungs 1–2 of the escalation ladder (see CODING_STANDARDS.md):
// `output: 'static'` builds to plain HTML for Cloudflare Pages with zero client
// JS by default. To reach rung 4 (edge SSR / Workers), add `@astrojs/cloudflare`
// as the adapter and switch `output` to 'server'.
export default defineConfig({
	output: 'static',
	vite: {
		server: {
			// `.ts.net` allows on-device testing over Tailscale HTTPS; the watch
			// ignores keep Nix/direnv churn from tripping inotify (ENOSPC) on NixOS.
			allowedHosts: ['.ts.net'],
			watch: { ignored: ['**/.direnv/**', '**/.git/**'] },
		},
	},
});
