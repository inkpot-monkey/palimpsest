import AxeBuilder from '@axe-core/playwright';
import { expect, test } from '@playwright/test';

// Opt-in accessibility recipe (#102). Fails on any WCAG 2.0/2.1 level A & AA
// violation on the home page. Copy this per route you want covered, or crawl a
// route list. Visual-regression / SEO / Lighthouse assertions are left to each
// site — this is the blessed accessibility floor, not a ceiling.
test('home page has no detectable a11y violations', async ({ page }) => {
	await page.goto('/');
	const results = await new AxeBuilder({ page })
		.withTags(['wcag2a', 'wcag2aa', 'wcag21a', 'wcag21aa'])
		.analyze();
	expect(results.violations).toEqual([]);
});
