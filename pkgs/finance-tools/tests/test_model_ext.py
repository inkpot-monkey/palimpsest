import unittest
from unittest.mock import MagicMock, patch
import json
from finance_extensions.model_ext import ModelExtension

class TestModelExtension(unittest.TestCase):
    def setUp(self):
        self.ledger = MagicMock()
        self.ext = ModelExtension(self.ledger)

    @patch("finance_extensions.model_ext.subprocess.run")
    @patch("finance_extensions.model_ext.jsonify")
    def test_explain_endpoint_success(self, mock_json, mock_run):
        # Mock successful subprocess
        mock_run.return_value.stdout = "AI Explanation"
        mock_run.return_value.returncode = 0
        
        # Mock Flask request
        with patch("finance_extensions.model_ext.request", MagicMock()) as mock_req:
            mock_req.get_json.return_value = {"message": "Error", "context": "Context"}
            
            # Call endpoint
            # Note: The @extension_endpoint decorator might wrap the function.
            # In Fava, it registers the route but usually returns the function itself (or a wrapper).
            # We call it directly.
            response = self.ext.explain()
            
            # Response is a tuple (json, code) or just json. Flask jsonify returns a Response object.
            # Since we mock flask.jsonify, we need to inspect what we return.
            # But the code imports jsonify from flask.
            # Real jsonify requires an app context. We should mock jsonify too or just check args.
            
            # However, typically unit testing Flask apps is best done with app.test_client().
            # As an extension, we are isolated. Mocking everything is brittle.
            # Let's verify the subprocess call logic which is the critical part.
            
            args, kwargs = mock_run.call_args
            self.assertIn("ollama", args[0])
            self.assertIn("run", args[0])
            self.assertEqual(kwargs['timeout'], 30)

    @patch("finance_extensions.model_ext.subprocess.run")
    def test_explain_endpoint_timeout(self, mock_run):
        import subprocess
        mock_run.side_effect = subprocess.TimeoutExpired(cmd="ollama", timeout=30)
        
        with patch("finance_extensions.model_ext.request", MagicMock()) as mock_req:
            mock_req.get_json.return_value = {"message": "msg"}
            
            # We need to run this in a context where jsonify works, or we mock jsonify
            with patch("finance_extensions.model_ext.jsonify") as mock_json:
                response = self.ext.explain()
                mock_json.assert_called_with({"success": False, "error": "AI request timed out"})

    def test_status(self):
         with patch("finance_extensions.model_ext.jsonify") as mock_json:
             self.ext.status()
             mock_json.assert_called_with({"status": "OK", "extension": "ModelExtension"})

if __name__ == '__main__':
    unittest.main()
