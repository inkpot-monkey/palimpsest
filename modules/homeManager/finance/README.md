# Nix Personal Finance Module

A robust, privacy-first personal finance management system built for NixOS/Home Manager.

## Overview
This module provides a fully declarative environment for:
1.  **Ingesting** financial data from CSV exports (Revolut, N26, Santander).
2.  **Tagging & Categorizing** transactions automatically using a **Local LLM** (Qwen 2.5 7B running on Ollama).
3.  **Visualizing** the ledger using Fava.

## Design Philosophy

### 1. Privacy First
All AI processing happens **locally** on your machine.
- **No API Keys**: We do not use OpenAI, Anthropic, or any cloud provider.
- **Local Model**: The system automatically pulls and manages a local instance of `qwen2.5:7b` via Ollama.
- **Data Sovereignty**: Your financial data never leaves `localhost`.

### 2. Paranoid Integrity ("Anchor Invariance")
We do not trust the AI to modify critical financial data. The ingestion pipeline implements strict **integrity checks**:
- **Deep Copy Snapshot**: Incoming data is snapshotted before AI processing.
- **Anchor Invariance**: The AI is allowed to suggest categories (accounts) and payees, but it is **strictly forbidden** from modifying:
    - The Transaction Date.
    - The "Anchor Posting" (the source bank account, amount, and currency).
- **Crash-Early**: If the AI hallucinates or corrupts the anchor data, the process immediately raises a `RuntimeError` and aborts, preventing ledger corruption.

### 3. Declarative & Reproducible
- The Python tooling (`finance-tools`) is packaged with `buildPythonApplication` in Nix.
- Dependencies (`beancount`, `fava`, `litellm`) are locked and built deterministically.
- Systemd services manage the lifecycle of the AI server and ingestion timers.

## Architecture

### Components

#### 1. Python Package (`finance-tools`)
Located in `./package.nix`, this derivation builds the custom Python logic:
- `ingest.py`: CLI entrypoint for ingestion.
- `importers/*.py`: Custom Beancount importers for specific banks.
- `hooks/smart_tagger.py`: The AI logic. It queries `http://localhost:11434` and implements the integrity verification.

#### 2. Systemd Services
The module (`default.nix`) defines three user services:
- **`ollama-ensure-model.service`**: 
    - Checks if Ollama is reachable.
    - Automatically runs `ollama pull qwen2.5:7b` to ensure the model exists.
    - One-shot service that runs on login/startup.
- **`finance-fetch.service`**:
    - Runs the ingestion process (`finance-ingest`).
    - Depends on `ollama-ensure-model`.
    - Triggered by a timer (daily).
- **`fava.service`**:
    - Runs the web UI on `localhost:5000`.

## Configuration

To use this module, import it in your Home Manager configuration and enable it:

```nix
# home.nix
imports = [
  ../../modules/home-manager/finance
];

programs.finance.enable = true;
```

### Options
- `programs.finance.dataDir`: Where your CSVs and ledger files live (Default: `~/finance`).
- `programs.finance.configDir`: Where your `config.py` lives (Default: `~/.config/finance`).

## Usage

### Manual Ingestion
To manually trigger the ingestion process (e.g., after adding new CSVs):

```bash
finance-ingest
```
*This wrapper checks if Ollama is running. If offline, it warns and skips AI tagging but still ingests the data safeley.*

### Viewing the Ledger
Open your browser to the Fava dashboard:
http://127.0.0.1:5000

### Checking AI Status
To see if the local model is pulled and ready:
```bash
ollama list
# Should show qwen2.5:7b
```

## Directory Structure
```text
finance/
├── default.nix            # Home Manager module (services, config)
├── package.nix            # Python application derivation
├── pyproject.toml         # Python project metadata
├── ingest.py              # Main ingestion script
├── config.py              # Importer configuration
├── hooks/
│   └── smart_tagger.py    # AI logic & Integrity Checks
└── importers/             # Bank-specific logic
    ├── n26.py
    └── revolut.py
```
