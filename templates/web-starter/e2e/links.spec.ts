import { expect, test } from '@playwright/test';

// Opt-in broken-link recipe (#102). Collects same-origin <a href> on the home
// page and asserts each resolves without a 4xx/5xx. Extend to crawl the whole
// site by seeding a queue from the sitemap.
test('internal links are not broken', async ({ page, request, baseURL }) => {
	await page.goto('/');
	const hrefs = await page
		.locator('a[href]')
		.evaluateAll((anchors) =>
			anchors
				.map((a) => (a as HTMLAnchorElement).getAttribute('href'))
				.filter((href): href is string => href !== null),
		);
	const internal = hrefs.filter(
		(href) => href.startsWith('/') || (baseURL !== undefined && href.startsWith(baseURL)),
	);
	for (const href of [...new Set(internal)]) {
		const response = await request.get(href);
		expect(response.status(), `link ${href}`).toBeLessThan(400);
	}
});
