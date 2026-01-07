from beangulp import Ingest
from config import CONFIG
from hooks.smart_tagger import SmartLLMHook

def main():
    # Ingest(CONFIG) creates a CLI application.
    # calling it parses sys.argv and runs the appropriate subcommand (identify, extract, etc)
    # We add our SmartLLMHook to the pipeline
    Ingest(CONFIG, hooks=[SmartLLMHook()])()

if __name__ == "__main__":
    main()
