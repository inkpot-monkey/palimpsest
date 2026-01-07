import unittest
from unittest.mock import patch, mock_open
import os
from pathlib import Path
from utils.config import get_config_dir, get_model_name, get_expense_patterns, load_ai_config

class TestConfig(unittest.TestCase):
    
    @patch.dict(os.environ, {"XDG_CONFIG_HOME": "/tmp/custom_config"})
    def test_get_config_dir_xdg(self):
        expected = Path("/tmp/custom_config/finance")
        self.assertEqual(get_config_dir(), expected)

    @patch("utils.config.load_ai_config")
    def test_get_model_name_defaults(self, mock_load):
        # Case 1: No config loaded
        mock_load.return_value = {}
        self.assertEqual(get_model_name(None), "ollama/qwen2.5:7b")

        # Case 2: Config has model
        mock_load.return_value = {"model": "custom/model"}
        self.assertEqual(get_model_name(None), "custom/model")

    @patch("utils.config.load_ai_config")
    def test_get_expense_patterns(self, mock_load):
        mock_load.return_value = {"expense_patterns": ["Food", "Transport"]}
        self.assertEqual(get_expense_patterns(None), ["Food", "Transport"])
        
        mock_load.return_value = {}
        self.assertEqual(get_expense_patterns(None), ["Expenses", "Income"])

if __name__ == '__main__':
    unittest.main()
