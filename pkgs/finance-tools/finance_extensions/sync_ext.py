from fava.ext import FavaExtensionBase, extension_endpoint
from flask import jsonify
import subprocess
import os
import shutil

class SyncExtension(FavaExtensionBase):
    report_title = "Sync Data"

    @extension_endpoint(methods=["POST"])
    def sync(self):
        from flask import Response, stream_with_context
        
        def generate():
            script_path = os.environ.get("FINANCE_INGEST_CMD", "finance-ingest")
            
            if not shutil.which(script_path):
                yield f"ERROR: Command '{script_path}' not found in PATH.\n"
                return

            yield f"Starting sync with: {script_path}\n"
            
            try:
                # Use Popen to stream output
                process = subprocess.Popen(
                    [script_path],
                    stdout=subprocess.PIPE,
                    stderr=subprocess.STDOUT,
                    text=True,
                    bufsize=1,
                    env=os.environ.copy()
                )
                
                # Stream lines as they come
                for line in process.stdout:
                    yield line
                
                process.wait()
                
                if process.returncode == 0:
                    yield "\nSUCCESS: Sync completed."
                else:
                    yield f"\nFAILED: Process exited with code {process.returncode}"
                    
            except Exception as e:
                yield f"\nERROR: {str(e)}"

        return Response(stream_with_context(generate()), mimetype='text/plain')
