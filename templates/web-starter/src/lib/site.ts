// Single source of truth for site-wide metadata. Define it ONCE here; the
// layout, pages, and any future feed/sitemap derive from it so they can't drift
// (the "define once / derive both" discipline — see CODING_STANDARDS.md).

export interface NavItem {
	label: string;
	href: string;
}

export interface SiteConfig {
	/** Human title, used in <title> and the header. */
	title: string;
	/** Default meta description; pages may override per-page. */
	description: string;
	/** Canonical origin, no trailing slash. */
	url: string;
	/** Primary navigation, in order. */
	nav: NavItem[];
}

export const site: SiteConfig = {
	title: 'web-starter',
	description: 'A static-first Astro site with a vanilla-CSS design-token system.',
	url: 'https://example.com',
	nav: [
		{ label: 'Home', href: '/' },
		{ label: 'About', href: '/about' },
	],
};
