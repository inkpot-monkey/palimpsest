import unittest
import os
import sys
from unittest.mock import patch, MagicMock
from beancount.core import data, amount, number
import datetime

# Ensure we can import from parent directory
sys.path.append(os.path.abspath(os.path.join(os.path.dirname(__file__), '..')))

from hooks.smart_tagger import SmartLLMHook

class TestPromptConstruction(unittest.TestCase):
    @patch('hooks.smart_tagger.completion')
    def test_prompt_content(self, mock_completion):
        # Setup
        hook = SmartLLMHook()
        txn = data.Transaction(
            {}, datetime.date(2023, 10, 27), "*", "", "UBER *TRIP", set(), set(),
            [data.Posting("Assets:US:Bank", amount.Amount(number.D("-24.50"), "USD"), None, None, None, None)]
        )

        # Execute
        # We need to force 'needs_help' logic in the hook or just call predict directly
        # calling predict directly is cleaner for unit testing the prompt
        hook.predict(txn)

        # Assert
        # Check what arguments were passed to completion()
        args, kwargs = mock_completion.call_args
        messages = kwargs['messages']
        user_message = messages[1]['content']
        
        print(f"\nGenerared Prompt:\n{user_message}")

        self.assertIn("UBER *TRIP", user_message)
        self.assertIn("-24.50", user_message)
        self.assertIn("JSON", user_message)

if __name__ == '__main__':
    unittest.main()
