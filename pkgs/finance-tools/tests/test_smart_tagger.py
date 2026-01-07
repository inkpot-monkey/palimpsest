import unittest
from unittest.mock import MagicMock, patch
from beancount.core import data, amount, number
from hooks.smart_tagger import SmartLLMHook
import datetime

class TestSmartLLMHook(unittest.TestCase):
    
    @patch("hooks.smart_tagger.load_ai_config")
    def setUp(self, mock_load):
        mock_load.return_value = {} # Default config
        self.hook = SmartLLMHook()
        # Create some dummy data
        self.txn = data.Transaction(
            meta={}, date=datetime.date(2023, 1, 1), flag="*", payee=None, narration="Uber Ride", tags=set(), links=set(), postings=[
                data.Posting("Assets:Bank", amount.Amount(number.D("-10.00"), "USD"), None, None, None, None)
            ]
        )

    def test_integrity_check(self):
        # Test that modification of date raises error
        original = [self.txn]
        modified = [self.txn._replace(date=datetime.date(2023, 1, 2))]
        
        with self.assertRaisesRegex(RuntimeError, "Date changed"):
            self.hook.verify_integrity(original, modified)

    @patch("hooks.smart_tagger.completion")
    def test_predict_flow(self, mock_completion):
        # Mock AI response
        mock_completion.return_value.choices[0].message.content = '{"account": "Expenses:Transport", "payee": "Uber"}'
        
        # Test predict method directly
        config = self.hook.predict(self.txn)
        self.assertEqual(config['account'], "Expenses:Transport")
        self.assertEqual(config['payee'], "Uber")

    def test_filter_patterns(self):
        # Ensure regex/pattern logic in loop works (we can't easily test the loop without mocking the whole __call__ context or history)
        # But we can check that expense_patterns are loaded correctly
        self.assertEqual(self.hook.expense_patterns, ["Expenses", "Income"])

if __name__ == '__main__':
    unittest.main()
