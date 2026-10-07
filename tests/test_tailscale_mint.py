import contextlib
import io
import json
import os
from pathlib import Path
import re
import runpy
import unittest
from unittest.mock import patch

class MintTests(unittest.TestCase):
    def test_single_use_scoped_key_and_valid_description(self):
        calls=[]
        class Response:
            def __enter__(self): return self
            def __exit__(self,*args): pass
            def read(self):
                return json.dumps({'access_token':'test-access'} if len(calls)==1 else {'key':'test-auth'}).encode()
        def send(request,timeout):
            calls.append(request);return Response()
        script=Path(__file__).resolve().parents[1]/'provision/mint-tailscale-auth-key.py'
        with patch.dict(os.environ,{'TS_API_CLIENT_ID':'fake','TS_API_CLIENT_SECRET':'fake','TS_HOSTNAME':'ipc-e2e-01','TS_TAGS':'tag:ipc'}),patch('urllib.request.urlopen',side_effect=send),contextlib.redirect_stdout(io.StringIO()) as out:
            runpy.run_path(str(script),run_name='__main__')
        self.assertEqual(out.getvalue(),'test-auth')
        body=json.loads(calls[1].data)
        self.assertRegex(body['description'],r'^[A-Za-z0-9 _-]+$')
        self.assertEqual(body['capabilities']['devices']['create'],{'reusable':False,'ephemeral':False,'preauthorized':False,'tags':['tag:ipc']})
        self.assertEqual(body['expirySeconds'],7*86400)

    def test_expiry_outside_tailscale_limits_is_rejected(self):
        script=Path(__file__).resolve().parents[1]/'provision/mint-tailscale-auth-key.py'
        with patch.dict(os.environ,{'TS_API_CLIENT_ID':'fake','TS_API_CLIENT_SECRET':'fake','TS_HOSTNAME':'ipc-e2e-01','TS_AUTHKEY_EXPIRY_SECONDS':str(91*86400)}),patch('urllib.request.urlopen',side_effect=AssertionError('no API call expected')),contextlib.redirect_stderr(io.StringIO()):
            with self.assertRaises(SystemExit):
                runpy.run_path(str(script),run_name='__main__')

if __name__=='__main__':unittest.main()
