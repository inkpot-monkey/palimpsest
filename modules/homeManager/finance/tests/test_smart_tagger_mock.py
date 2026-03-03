import os
import sys
import unittest
from unittest.mock import MagicMock, patch
from beancount.core import data, amount, number

# Ensure we can import from parent directory
sys.path.append(os.path.abspath(os.path.join(os.path.dirname(__file__), '..')))

from hooks.smart_tagger import SmartLLMHook
import datetime
import os

class TestSmartLLMHook(unittest.TestCase):
    @patch('hooks.smart_tagger.completion')
    def test_predict_and_tag(self, mock_completion):
        # 1. Setup Mock LLM Response
        # We simulate a valid JSON response from the LLM
        mock_response = MagicMock()
        mock_response.choices = [
            MagicMock(message=MagicMock(content='{"account": "Expenses:Test:Category", "payee": "AI Payee"}'))
        ]
        mock_completion.return_value = mock_response

        # 2. Force Environment check to pass by setting the key temporarily
        # We do this context manager style or just patch os.environ in the setup
        with patch.dict(os.environ, {"OPENAI_API_KEY": "fake-key"}):
            
            # 3. Create a sample transaction (1 leg)
            # This represents a raw bank import
            txn = data.Transaction(
                {}, datetime.date(2025, 1, 1), "*", "Original Payee", "Test Transaction Description", set(), set(),
                [
                    data.Posting("Assets:Bank", amount.Amount(number.D("-10.00"), "USD"), None, None, None, None)
                ]
            )
            entries = [txn]

            # 4. Run Hook
            hook = SmartLLMHook()
            new_entries = hook(entries, [])

            # 5. Assertions
            self.assertEqual(len(new_entries), 1)
            new_txn = new_entries[0]
            
            # Should have 2 postings now (Bank + Expense)
            self.assertEqual(len(new_txn.postings), 2)
            
            # Check the new posting (Expense)
            expense_posting = new_txn.postings[1]
            self.assertEqual(expense_posting.account, "Expenses:Test:Category")
            # Amount should be flipped (-10 -> +10)
            self.assertEqual(expense_posting.units.number, number.D("10.00")) 
            
            # Check Payee update
            self.assertEqual(new_txn.payee, "AI Payee")
            
            print("Mock Test Passed: Logic correctly applied AI suggestions.")

if __name__ == '__main__':
    unittest.main()
