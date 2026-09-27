import csv
import os

from beancount.core import amount, data, number
from beangulp import Importer
from dateutil.parser import parse


class N26Importer(Importer):
    def __init__(self, account):
        self.account_name = account

    def account(self, filepath):
        return self.account_name

    def identify(self, filepath):
        if "n26" not in os.path.basename(filepath).lower():
            return False
        try:
            with open(filepath) as f:
                header = f.readline().strip()
                # N26 typical header columns
                return (
                    '"date"' in header.lower()
                    and '"payee"' in header.lower()
                    and '"amount (eur)"' in header.lower()
                )
        except (OSError, UnicodeDecodeError):
            # Unreadable, or not a text file at all -- either way it is not ours.
            return False

    def extract(self, filepath, existing_entries=None):
        entries = []
        with open(filepath) as f:
            reader = csv.DictReader(f)
            for index, row in enumerate(reader):
                meta = data.new_metadata(filepath, index)
                date = parse(row.get("Date")).date()
                desc = row.get("Payee")
                amt_str = row.get("Amount (EUR)")
                units = amount.Amount(number.D(amt_str), "EUR")

                txn = data.Transaction(
                    meta,
                    date,
                    "*",
                    "",
                    desc,
                    data.EMPTY_SET,
                    data.EMPTY_SET,
                    [
                        data.Posting(self.account_name, units, None, None, None, None),
                    ],
                )
                entries.append(txn)
        return entries
