import unittest
import os
import sys

# Ensure we can import from parent directory
sys.path.append(os.path.abspath(os.path.join(os.path.dirname(__file__), '..')))

from hooks.smart_tagger import SmartLLMHook
from unittest.mock import patch

class TestAnthropicSwitch(unittest.TestCase):
    def test_default_is_gpt(self):
        """Test that default is GPT-3.5 when no Anthropic key is present"""
        # Ensure env is clear for this test
        with patch.dict(os.environ, {}, clear=True):
             hook = SmartLLMHook()
             self.assertEqual(hook.model, "gpt-3.5-turbo")

    def test_detects_anthropic(self):
        """Test that presence of ANTHROPIC_API_KEY switches model to Claude"""
        with patch.dict(os.environ, {"ANTHROPIC_API_KEY": "fake-key"}, clear=True):
            hook = SmartLLMHook()
            self.assertEqual(hook.model, "claude-3-haiku-20240307")
            print(f"Success: Hook switched to {hook.model} when Anthropic key detected.")

if __name__ == '__main__':
    unittest.main()
