import os
import json
import sys
from pathlib import Path
from typing import Dict, Any, Optional

def get_config_dir() -> Path:
    """Resolve the configuration directory following XDG standards."""
    xdg_config = os.environ.get("XDG_CONFIG_HOME", os.path.expanduser("~/.config"))
    return Path(xdg_config) / "finance"

def load_ai_config() -> Dict[str, Any]:
    """Load the AI configuration from ai_config.json."""
    config_path = get_config_dir() / "ai_config.json"
    try:
        if config_path.exists():
            with open(config_path, 'r') as f:
                return json.load(f)
    except Exception as e:
        print(f"Warning: Failed to load ai_config.json: {e}", file=sys.stderr)
    return {}

def get_model_name(config: Optional[Dict[str, Any]] = None) -> str:
    """Get the model name from config or default."""
    if config is None:
        config = load_ai_config()
    
    model = config.get("model", "ollama/qwen2.5:7b")
    # Ensure consistency with how we expect model names (e.g. for litellm vs ollama CLI)
    # The consumers (smart_tagger vs model_ext) might handle prefixes differently,
    # but centralizing the default here is good.
    return model

def get_expense_patterns(config: Optional[Dict[str, Any]] = None) -> list[str]:
    """Get expense account patterns."""
    if config is None:
        config = load_ai_config()
    return config.get("expense_patterns", ["Expenses", "Income"])
