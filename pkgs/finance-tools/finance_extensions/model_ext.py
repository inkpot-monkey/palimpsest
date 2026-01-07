from fava.ext import FavaExtensionBase, extension_endpoint
from flask import jsonify, request
import subprocess
import os
import json
from pathlib import Path
from utils.config import get_config_dir, get_model_name, load_ai_config
import logging

log = logging.getLogger(__name__)

class ModelExtension(FavaExtensionBase):
    report_title = "Auto tagging"

    @extension_endpoint(methods=["GET"])
    def status(self):
        print("DEBUG: status endpoint called", flush=True)
        # ... (unchanged code for status)
        # We need to preserve status implementation but I am using replace_file_content which requires context matching
        # Easier to just modify the class definition and add the method separately or use a larger chunk.
        # Let's target the class definition first.

    def __init__(self, ledger, config=None):
        log.debug("ModelExtension.__init__ called")
        super().__init__(ledger, config)
        # Enable JS module loading
        self.has_js_module = True
        log.debug(f"ModelExtension initialized. Endpoints detected: {self.endpoints}")

    def _get_config_path(self):
        return get_config_dir() / "ai_config.json"

    @extension_endpoint(methods=["GET"])
    def status(self):
        log.debug("status endpoint called")
        return jsonify({"status": "OK", "extension": "ModelExtension"})

    @extension_endpoint(methods=["POST"])
    def explain(self):
        log.debug("explain endpoint called")
        data = request.get_json()
        error_message = data.get("message", "")
        context = data.get("context", "")
        
        prompt = f"""
        Explain the following Beancount error to a user and suggest a fix.
        Error: {error_message}
        Context: {context}
        
        Keep it concise and helpful.
        """
        
        try:
            # Load config using shared util
            cfg = load_ai_config()
            model = get_model_name(cfg)

            # Ensure model has 'ollama/' prefix if needed or plain
            # The utils.config.get_model_name already defaults to "ollama/qwen2.5:7b"
            # We trust the config/default here.
                 # Wait, for subprocess call we use 'ollama run model'
                 # We don't use litellm here yet, we used subprocess in other methods.
                 # Let's use subprocess for consistency with 'pull' method in this class.
            
            try:
                res = subprocess.run(
                    ["ollama", "run", model, prompt],
                    capture_output=True,
                    text=True,
                    check=True,
                    timeout=30  # 30 second timeout for explanation
                )
                return jsonify({"success": True, "explanation": res.stdout.strip()})
            except subprocess.TimeoutExpired:
                 return jsonify({"success": False, "error": "AI request timed out"}), 504
        except Exception as e:
            return jsonify({"success": False, "error": str(e)}), 500

    @extension_endpoint(methods=["POST"])
    def model(self):
        # ...
        log.debug("model endpoint called")
        data = request.get_json()
        model = data.get("model")
        config_path = self._get_config_path()
        try:
            config_path.parent.mkdir(parents=True, exist_ok=True)
            with open(config_path, "w") as f:
                json.dump({"model": model}, f)
            return jsonify({"success": True})
        except Exception as e:
            return jsonify({"success": False, "error": str(e)}), 500

    @extension_endpoint(methods=["POST"])
    def pull(self):
        log.debug("pull endpoint called")
        data = request.get_json()
        model = data.get("model")
        try:
            res = subprocess.run(
                ["ollama", "pull", model], 
                capture_output=True, 
                text=True, 
                check=True,
                timeout=300 # 5 minute timeout for pull
            )
            return jsonify({"success": True, "output": res.stdout})
        except subprocess.CalledProcessError as e:
            return jsonify({"success": False, "error": e.stderr}), 500
        except Exception as e:
            return jsonify({"success": False, "error": str(e)}), 500
