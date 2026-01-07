import os
import sys

# Add current directory to path so we can import 'importers'
sys.path.append(os.path.dirname(__file__))

from importers.revolut import RevolutImporter
from importers.n26 import N26Importer
from importers.santander import SantanderImporter

CONFIG = [
    RevolutImporter("Assets:Revolut:Current"),
    N26Importer("Assets:N26:Current"),
    SantanderImporter("Assets:Santander:Current"),
]
