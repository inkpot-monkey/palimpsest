import os
from litellm import completion
from beangulp import Importer
from beancount.core import data

import sys
from typing import List, Dict, Any, Optional
from utils.config import load_ai_config, get_model_name, get_expense_patterns

# Simple LLM Tagger Hook
class SmartLLMHook:
    """
    Applied as a hook to beangulp importers.
    If a transaction lacks a payee or has an unknown account,
    it queries a local Ollama instance via LiteLLM.
    """
    def __init__(self, model: str = "ollama/qwen2.5:7b", api_base: str = "http://localhost:11434"):
        """
        Initialize the hook.
        :param model: LLM model to use (default: ollama/qwen2.5:7b)
        :param api_base: Ollama API base URL
        """
        self.api_base = api_base
        self.api_key = "ollama" 

        # Load override from config if present
        try:
            config = load_ai_config()
            # If config has a model, it takes precedence over the default arg (or we could use it as fallback)
            # The get_model_name helper does this logic if we pass None, but we have a default arg here.
            # Let's trust the config file if it exists.
            if config:
                self.model = get_model_name(config)
                self.expense_patterns = get_expense_patterns(config)
                print(f"Loaded AI model from config: {self.model}", file=sys.stderr)
            else:
                 self.model = model
                 self.expense_patterns = ["Expenses", "Income"]

        except Exception as e:
            print(f"Warning: Failed to load config: {e}", file=sys.stderr)
            self.model = model
            self.expense_patterns = ["Expenses", "Income"]

    def _check_ollama(self) -> bool:
        """Check if Ollama is reachable."""
        import urllib.request
        try:
            # Simple check to tags endpoint
            with urllib.request.urlopen(f"{self.api_base}/api/tags", timeout=2) as response:
                return response.status == 200
        except Exception:
            return False

    def __call__(self, entries, existing_entries):
        # Health check
        if not self._check_ollama():
            print(f"Warning: Ollama not reachable at {self.api_base}. Skipping AI tagging.", file=sys.stderr)
            return entries

        # 0. DEEP COPY for Paranoid Integrity Check
        # We keep a pristine snapshot of what came in to ensure the AI uses "Anchor Invariance"
        import copy
        original_snapshot = copy.deepcopy(entries)

        # Build History Cache from existing ledger
        # Map: "Payee|Description" -> {account, payee}
        history_cache = {}
        for entry in existing_entries:
            if isinstance(entry, data.Transaction):
                 # We only learn from transactions
                 key = entry.narration.strip()
                 # Find the expense posting
                 expense_posting = None
                 for p in entry.postings:
                     if p.units.number > 0 and any(p.account.startswith(pat) for pat in self.expense_patterns):
                         expense_posting = p
                         break
                 
                 if expense_posting:
                     history_cache[key] = {
                         'account': expense_posting.account,
                         'payee': entry.payee
                     }

        new_entries = []
        for entry in entries:
            if isinstance(entry, data.Transaction):
                # Check if we need to tag it
                needs_help = False
                if len(entry.postings) == 1:
                    needs_help = True
                elif len(entry.postings) > 1:
                     if "Unknown" in entry.postings[1].account:
                         needs_help = True
                
                if needs_help:
                    description = entry.narration.strip()
                    print(f"DEBUG: Processing entry: {description}", file=sys.stderr)
                    
                    # 1. Try Cache
                    if description in history_cache:
                        cached = history_cache[description]
                        print(f"Ref: Found cached entry for '{description}' -> {cached['account']}", file=sys.stderr)
                        predicted = {'account': cached['account'], 'payee': cached['payee']}
                        is_cached = True
                    else:
                        # 2. Ask AI
                        print(f"DEBUG: Asking AI for {description}...", file=sys.stderr)
                        predicted = self.predict(entry)
                        print(f"DEBUG: AI Prediction: {predicted}", file=sys.stderr)
                        is_cached = False

                    if predicted:
                        # Update entry
                        bank_posting = entry.postings[0]
                        print(f"DEBUG: Applying prediction {predicted}", file=sys.stderr)
                        
                        # Create new posting for the predicted expense
                        units = bank_posting.units
                        if units:
                           units = -units
                        
                        expense_posting = data.Posting(
                            predicted['account'],
                            units,
                            None, None, None, None
                        )
                        
                        new_postings = [bank_posting, expense_posting]
                        
                        # Replace the transaction with updated one
                        entry = entry._replace(postings=new_postings)
                        if predicted.get('payee'):
                             entry = entry._replace(payee=predicted['payee'])
                        
                        # Add #ai tag
                        new_tags = set(entry.tags) if entry.tags else set()
                        new_tags.add('ai')
                        entry = entry._replace(tags=new_tags)
                    else:
                         print(f"DEBUG: Prediction failed/empty for {description}", file=sys.stderr)

            new_entries.append(entry)

        # 3. VERIFY INTEGRITY
        # This will raise RuntimeError if the AI messed up the anchor data
        self.verify_integrity(original_snapshot, new_entries)

        return new_entries

    def verify_integrity(self, original_entries, processed_entries):
        """
        Enforce 'Anchor Invariance'.
        The AI is allowed to change payee, narration, and add postings.
        It is NOT allowed to change:
        - The date
        - The anchor posting (account and amount/currency of the first posting)
        """
        if len(original_entries) != len(processed_entries):
            raise RuntimeError(f"Integrity Failure: Entry count mismatch. Original: {len(original_entries)}, Processed: {len(processed_entries)}")

        for i, (orig, proc) in enumerate(zip(original_entries, processed_entries)):
            # Debugging types if integrity fails
            if not hasattr(orig, 'date'):
                 # It might be a plain tuple or something else.
                 # In Beancount, everything should be a Directive (namedtuple) with a date.
                 # If it's not, we should check why.
                 # Skip objects without date, but warn.
                 # print(f"Warning: Entry at {i} has no date. Type: {type(orig)} Valid integrity check skipping.", file=sys.stderr)
                 continue

            # 1. Date Check
            if orig.date != proc.date:
                 raise RuntimeError(f"Integrity Failure at index {i}: Date changed from {orig.date} to {proc.date}. Transaction: {orig.narration}")

            # 2. Anchor Check (Only for Transactions)
            if isinstance(orig, data.Transaction) and isinstance(proc, data.Transaction):
                if not orig.postings:
                    continue # Should not happen in valid beancount but safe to skip

                anchor_orig = orig.postings[0]
                
                # We expect the anchor to still be present in the processed transaction.
                # Usually it is preserved as the first posting, but strictly speaking we just need TO FIND IT.
                # However, for our pipeline, we assume index 0 is the anchor.
                if not proc.postings:
                     raise RuntimeError(f"Integrity Failure at index {i}: Processed transaction has no postings. Original had {len(orig.postings)}.")

                anchor_proc = proc.postings[0]

                # Check Account
                if anchor_orig.account != anchor_proc.account:
                     raise RuntimeError(f"Integrity Failure at index {i}: Anchor account changed. Original: {anchor_orig.account}, Processed: {anchor_proc.account}")

                # Check Units (Amount + Currency)
                if anchor_orig.units != anchor_proc.units:
                     raise RuntimeError(f"Integrity Failure at index {i}: Anchor amount changed. Original: {anchor_orig.units}, Processed: {anchor_proc.units}")


    def predict(self, entry: data.Transaction) -> Optional[Dict[str, str]]:
        # Construct prompt
        description = entry.narration
        date = entry.date
        amount = entry.postings[0].units
        
        prompt = f"""
        Interpret this bank transaction and suggest a Beancount expense account and payee.
        Transaction: {date} "{description}" {amount}
        
        Return valid JSON only: {{"account": "Expenses:Category:Subcategory", "payee": "Clean Payee Name"}}
        Standard accounts: Expenses:Food:Groceries, Expenses:Food:Restaurant, Expenses:Transport, Expenses:Utilities, Expenses:Shopping.
        """
        
        try:
            response = completion(
                model=self.model,
                api_base=self.api_base,
                api_key=self.api_key,
                messages=[
                    {"role": "system", "content": "You are a helpful accounting assistant. Return JSON only."},
                    {"role": "user", "content": prompt}
                ],
                temperature=0.0,
            )
            content = response.choices[0].message.content.strip()
            # Simple parsing (using eval/json)
            import json
            # find first { and last }
            start = content.find('{')
            end = content.rfind('}') + 1
            if start != -1 and end != -1:
                return json.loads(content[start:end])
        except Exception as e:
            print(f"LiteLLM Error: {e}", file=sys.stderr)
            return None

