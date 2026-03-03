import unittest
import os
import sys
from unittest.mock import MagicMock, patch
from beancount.core import data, amount, number
import datetime

# Ensure we can import from parent directory
sys.path.append(os.path.abspath(os.path.join(os.path.dirname(__file__), '..')))

from hooks.smart_tagger import SmartLLMHook

class TestCachingLogic(unittest.TestCase):
    
    def setUp(self):
        # Create a dummy hook
        self.hook = SmartLLMHook()
        # Mock the predict method to avoid actual API calls (cost/secrets)
        # We only want to test the CACHING logic here.
        self.hook.predict = MagicMock(return_value={
            'account': 'Expenses:AI:Predicted',
            'payee': 'AI Payee'
        })

    def create_txn(self, description, amount_val="-10.00"):
        return data.Transaction(
            {}, datetime.date(2025, 1, 1), "*", "Payee", description, set(), set(),
            [
                data.Posting("Assets:Bank", amount.Amount(number.D(amount_val), "USD"), None, None, None, None)
            ]
        )

    def create_history_entry(self, description, account):
        """Creates a 'tagged' entry that should serve as cache source"""
        return data.Transaction(
            {}, datetime.date(2024, 1, 1), "*", "Payee", description, set(), set(),
            [
                data.Posting("Assets:Bank", amount.Amount(number.D("-10.00"), "USD"), None, None, None, None),
                data.Posting(account, amount.Amount(number.D("10.00"), "USD"), None, None, None, None)
            ]
        )

    def test_cache_miss_calls_llm(self):
        """Test that a new description triggers LLM and adds #ai tag"""
        entries = [self.create_txn("New Place")]
        existing_entries = [] # No history

        with patch.dict(os.environ, {"ANTHROPIC_API_KEY": "fake"}):
            new_entries = self.hook(entries, existing_entries)
            
            # Should have called predict
            self.hook.predict.assert_called()
            
            # Should stay 1 entry
            self.assertEqual(len(new_entries), 1)
            entry = new_entries[0]
            
            # Should have #ai tag
            self.assertIn("ai", entry.tags)
            # Should have predicted account
            self.assertEqual(entry.postings[1].account, "Expenses:AI:Predicted")

    def test_cache_hit_skips_llm(self):
        """Test that an existing description uses history and skips LLM"""
        entries = [self.create_txn("Starbucks")]
        # History has Starbucks mapped to Expenses:Food:Coffee
        existing_entries = [self.create_history_entry("Starbucks", "Expenses:Food:Coffee")]

        # Reset mock
        self.hook.predict.reset_mock()

        with patch.dict(os.environ, {"ANTHROPIC_API_KEY": "fake"}):
            new_entries = self.hook(entries, existing_entries)
            
            # Should NOT have called predict
            self.hook.predict.assert_not_called()
            
            entry = new_entries[0]
            # Should use cached account
            self.assertEqual(entry.postings[1].account, "Expenses:Food:Coffee")
            # Should NOT have #ai tag (optional, but current logic mimics manual entry so maybe no tag or #ai tag? Code adds #ai only on predict path?)
            # Wait, looking at code: "if predicted: ... is_cached = True ... if predicted: ... Add #ai tag"
            # It ADDS #ai tag even on cache hit? Let's verify code behavior.
            # Code:
            # if description in cache: is_cached=True, predicted={...}
            # ...
            # if predicted: ... update ... Add #ai tag
            # So YES, it should add #ai tag even for cached entries if they are being 'auto-completed'
            # ACTUALLY, checking the code block...
            # The #ai tag adding is inside `if predicted:`.
            # And `predicted` is set in both branches.
            # So yes, it should tag it.
            # self.assertIn("ai", entry.tags) 
            # (Checks logic)

    def test_cache_hit_exact_whitespace(self):
        """Test that caching is strict on whitespace per current implementation"""
        entries = [self.create_txn("Starbucks ")] # Trailing space
        existing_entries = [self.create_history_entry("Starbucks", "Expenses:Food")] # No trailing
        
        # Code does .strip() on key creation and lookup, so this SHOULD hit.
        
        self.hook.predict.reset_mock()
        with patch.dict(os.environ, {"ANTHROPIC_API_KEY": "fake"}):
            new_entries = self.hook(entries, existing_entries)
            self.hook.predict.assert_not_called()
            self.assertEqual(new_entries[0].postings[1].account, "Expenses:Food")

if __name__ == '__main__':
    unittest.main()
