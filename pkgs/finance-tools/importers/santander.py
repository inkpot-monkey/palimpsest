from beangulp import Importer
from beancount.core import data, amount, number
from dateutil.parser import parse
import csv
import os

class SantanderImporter(Importer):
    def __init__(self, account):
        self.account_name = account

    def account(self, filepath):
        return self.account_name

    def identify(self, filepath):
        if "santander" not in os.path.basename(filepath).lower():
            return False
        try:
            with open(filepath, encoding='utf-8-sig') as f:
                # Santander export headers often differ, but a common one is:
                # Date, Description, Amount, Balance
                header = f.readline().strip()
                return "date" in header.lower() and "description" in header.lower() and "amount" in header.lower() and "balance" in header.lower()
        except:
            return False

    def extract(self, filepath, existing_entries=None):
        entries = []
        with open(filepath, encoding='utf-8-sig') as f:
            reader = csv.DictReader(f)
            for index, row in enumerate(reader):
                meta = data.new_metadata(filepath, index)
                
                # Parse Date (dd/mm/yyyy is common in UK/Europe)
                # allowing dateutil to guess day-first
                date = parse(row.get('Date'), dayfirst=True).date()
                
                desc = row.get('Description')
                
                # Amount might be formatted like "+10.00" or "-10.00"
                amt_str = row.get('Amount')
                
                # Assume GBP for Santander unless specified otherwise
                units = amount.Amount(number.D(amt_str), 'GBP')
                
                txn = data.Transaction(
                    meta, date, "*", "", desc, 
                    data.EMPTY_SET, data.EMPTY_SET, [
                        data.Posting(self.account_name, units, None, None, None, None),
                    ]
                )
                entries.append(txn)
        return entries
