# AGENTS.md - finance-tools

Personal finance ingestion: CSV importers -> AI tagging via local LLM -> Beancount ledger.

## Build / lint / test

- **Build:** `nix build .#finance-tools` or `python -m build`
- **Shell (dev):** `nix-shell` (sets up PYTHONPATH, includes black + pylsp)
- **Lint:** `black --check .`
- **Format:** `black .`
- **Test all:** `python -m pytest tests/` or `python -m unittest discover -s tests`
- **Single test class:** `python -m pytest tests/test_smart_tagger.py -x -v`
- **Single test method:** `python -m unittest tests.test_smart_tagger.TestSmartLLMHook.test_predict_flow`
- **Run ingester:** `python ingest.py`

## Code style

- **Formatting:** black for Python
- **Testing:** unittest.TestCase with unittest.mock.patch (not pytest fixtures)
- **Types:** use typing module (List, Dict, Optional, Any) on public interfaces
- **Imports:** stdlib first, then third-party, then local (grouped with blank lines)
- **Naming:** snake_case for fns/vars, PascalCase for classes, SCREAMING_SNAKE for constants
- **Beancount:** use beancount.core.data types (Transaction, Posting, Amount) for ledger objects
- **AI hooks:** never mutate anchor fields (date, amount, source account) - crash on integrity violation
- **Config:** importer config in config.py, AI config loaded via utils.config.load_ai_config()
