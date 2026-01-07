# Beancount v3 Migration: beancount.ingest -> beangulp
from beangulp import Importer
from beancount.core import data, amount, number
from dateutil.parser import parse
import csv
import os

class RevolutImporter(Importer):
    def __init__(self, account):
        self.account_name = account

    def account(self, filepath):
        return self.account_name

    def identify(self, filepath):
        # beangulp passes the full path as a string (or path-like object)
        # Identify by filename or header
        if "revolut" not in os.path.basename(filepath).lower():
            return False
        
        # Check header
        try:
            with open(filepath) as f:
                header = f.readline().strip()
                # Basic check for typical Revolut columns
                return "started date" in header.lower() or "completed date" in header.lower()
        except:
            return False

    def extract(self, filepath, existing_entries=None):
        entries = []
        
        with open(filepath) as f:
            reader = csv.DictReader(f)
            for index, row in enumerate(reader):
                meta = data.new_metadata(filepath, index)
                
                # Parse Date (Completed Date is usually the booking date)
                date_str = row.get('Completed Date') or row.get('Started Date')
                date = parse(date_str).date()
                
                desc = row.get('Description', '')
                
                # Amount
                # Revolut CSVs can be messy. Adjust column names as needed.
                amt_str = row.get('Amount')
                curr = row.get('Currency', 'GBP')
                
                units = amount.Amount(number.D(amt_str), curr)
                
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
                    ]
                )
                entries.append(txn)
        
        return entries
