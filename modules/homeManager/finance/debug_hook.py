
from hooks.smart_tagger import SmartLLMHook
from beancount.core import data, amount, number
from datetime import date
import sys

# Mock transaction
entry = data.Transaction(
    meta={},
    date=date(2025, 1, 1),
    flag="*",
    payee="Tesco Groceries",
    narration="Tesco Groceries",
    tags=set(),
    links=set(),
    postings=[
        data.Posting("Assets:Revolut:Current", amount.Amount(number.D("-15.50"), "GBP"), None, None, None, None)
    ]
)

print("Testing SmartLLMHook...", file=sys.stderr)
hook = SmartLLMHook()
result = hook([entry], [])

if result and len(result[0].postings) == 2:
    print("SUCCESS: Hook added posting:", result[0].postings[1])
else:
    print("FAILURE: Hook did not add posting.", file=sys.stderr)
    print(f"Result postings: {len(result[0].postings)}", file=sys.stderr)
