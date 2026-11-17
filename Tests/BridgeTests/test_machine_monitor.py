import importlib.util
import json
from pathlib import Path
import tempfile
import unittest

source = Path(__file__).resolve().parents[2] / 'Sources/OpenAIQuotaBar/Resources/machine_monitor.py'
spec = importlib.util.spec_from_file_location('monitor', source)
monitor = importlib.util.module_from_spec(spec)
spec.loader.exec_module(monitor)


class MonitorTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.root = Path(self.temp.name)
        self.now = 1800000000
        self.budget = {'bytes': 0, 'limited': False}
    def tearDown(self):
        self.temp.cleanup()
    def stamp(self, age):
        return monitor.dt.datetime.fromtimestamp(self.now-age, monitor.dt.timezone.utc).isoformat()
    def file(self, name, rows):
        path = self.root/name
        path.write_text('\n'.join(json.dumps(row) for row in rows)+'\n')
        return path
    def codex(self, age, total):
        return {'type': 'event_msg', 'timestamp': self.stamp(age), 'payload': {'type': 'token_count', 'info': {'total_token_usage': {'total_tokens': total, 'input_tokens': total-10, 'output_tokens': 10, 'cached_input_tokens': total-30}}}}
    def test_codex_cumulative_totals_and_duplicate_events_are_not_double_counted(self):
        rows = [{'type': 'session_meta', 'payload': {'id': 'same-session'}}, self.codex(8*86400,1000), self.codex(2*86400,1200), self.codex(100,1250), self.codex(50,1250)]
        a=self.file('a.jsonl',rows); b=self.file('archive.jsonl',rows)
        result=monitor.codex_usage([a,b],self.now,self.budget)
        self.assertEqual(result['tokens7d'],250)
        self.assertEqual(result['tokens24h'],50)
        self.assertEqual(result['sessions7d'],1)
    def test_claude_snapshots_cache_creation_and_cache_reads(self):
        row={'type':'assistant','requestId':'req','sessionId':'session','timestamp':self.stamp(60),'message':{'id':'msg','content':'PRIVATE PROMPT MUST NOT LEAVE','usage':{'input_tokens':10,'cache_creation_input_tokens':20,'cache_read_input_tokens':30,'output_tokens':5}}}
        a=self.file('a.jsonl',[row,row])
        row['message']['usage']['output_tokens']=10
        b=self.file('b.jsonl',[row])
        result=monitor.claude_usage([a,b],self.now,self.budget)
        self.assertEqual(result['tokens24h'],70)
        self.assertEqual(result['cached7d'],30)
        self.assertEqual(result['sessions7d'],1)
        self.assertNotIn('PRIVATE',json.dumps(result))
    def test_invalid_lines_and_prompt_only_records_do_not_create_usage(self):
        p=self.file('a.jsonl',[{'message':'secret'}, {'type':'event_msg','payload':[]}, {'type':'assistant','message':{'usage':None}}])
        with p.open('a') as f: f.write('{bad json\n')
        self.assertEqual(monitor.codex_usage([p],self.now,self.budget)['tokens7d'],0)
        self.assertEqual(monitor.claude_usage([p],self.now,self.budget)['tokens7d'],0)
    def test_symlinks_are_not_followed(self):
        logs=self.root/'logs';logs.mkdir()
        secret=self.file('secret.jsonl',[{'secret':True}])
        (logs/'linked.jsonl').symlink_to(secret)
        self.assertEqual(monitor.recent_files([logs],self.now,self.budget),[])
    def test_future_records_are_not_counted(self):
        p=self.file('future.jsonl',[self.codex(-86400,500)])
        self.assertEqual(monitor.codex_usage([p],self.now,self.budget)['tokens24h'],0)
