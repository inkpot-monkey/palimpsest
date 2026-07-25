import { describe, expect, it } from 'vitest';
import { site } from '@/lib/site';

// The vitest floor (#102): one trivial example that exercises the typed content
// SSOT. Real sites replace/extend this — e.g. assert a derived view matches its
// catalogue so the two can't drift.
describe('site config', () => {
	it('has a non-empty title and description', () => {
		expect(site.title.length).toBeGreaterThan(0);
		expect(site.description.length).toBeGreaterThan(0);
	});

	it('has unique, root-relative nav hrefs', () => {
		const hrefs = site.nav.map((item) => item.href);
		expect(new Set(hrefs).size).toBe(hrefs.length);
		for (const href of hrefs) {
			expect(href.startsWith('/')).toBe(true);
		}
	});
});
