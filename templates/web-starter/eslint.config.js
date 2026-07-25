import js from '@eslint/js';
import tseslint from 'typescript-eslint';
import astro from 'eslint-plugin-astro';
import prettier from 'eslint-config-prettier';

// Flat config (#101): JS recommended, type-aware typescript-eslint on the TS
// sources, eslint-plugin-astro for `.astro`, and eslint-config-prettier last so
// formatting is left entirely to Prettier. Build output and the config files
// themselves are ignored (the latter avoids type-aware parsing complaints).
export default tseslint.config(
	{
		ignores: [
			'dist/',
			'.astro/',
			'node_modules/',
			'.direnv/',
			'astro.config.mjs',
			'eslint.config.js',
			'playwright.config.ts',
			'vitest.config.ts',
		],
	},
	js.configs.recommended,
	{
		files: ['**/*.ts', '**/*.tsx'],
		extends: [...tseslint.configs.recommendedTypeChecked],
		languageOptions: {
			parserOptions: {
				projectService: true,
				tsconfigRootDir: import.meta.dirname,
			},
		},
	},
	...astro.configs.recommended,
	prettier,
);
