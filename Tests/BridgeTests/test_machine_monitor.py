import importlib.util
import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch, MagicMock
import urllib.error

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

    def test_provider_windows_report_remaining_percent_without_inventing_token_balances(self):
        result=monitor.claude_windows({'five_hour':{'utilization':25.2,'resets_at':self.stamp(-100)},
            'seven_day':{'utilization':103},'seven_day_opus':{'utilization':float('nan')}})
        self.assertEqual([w['remainingPercent'] for w in result],[74.8,0])
        self.assertEqual(result[0]['resetsAt'],self.now+100)
        self.assertEqual(set(result[0]),{'name','remainingPercent','resetsAt'})
        result=monitor.codex_windows({'rateLimits':{'limitId':'another-model','primary':{'usedPercent':3}}})
        self.assertEqual(result,[])
        result=monitor.codex_windows({'rateLimitsByLimitId':{'codex':{'primary':{'usedPercent':12,'windowDurationMins':300}}}})
        self.assertEqual(result[0]['remainingPercent'],88)

    def profile(self, provider='claude', **values):
        return dict(id=provider+'-default',provider=provider,label='Default profile',default=True,**values)

    def test_claude_secrets_stay_in_local_requests_and_only_sanitized_account_fields_leave(self):
        secret='SENSITIVE_ACCESS_TOKEN'
        def get(endpoint,token):
            self.assertEqual(token,secret)
            if endpoint=='profile':
                return {'account':{'email':'test@example.com','private':secret},'organization':{'organization_type':'claude_max'}}
            return {'seven_day':{'utilization':44,'resets_at':self.stamp(-300)},'private':secret}
        with patch.object(monitor,'claude_credentials',return_value={'accessToken':secret,'refreshToken':'SENSITIVE_REFRESH'}),patch.object(monitor,'claude_get',side_effect=get):
            result=monitor.read_claude_account(self.profile(),self.root)
        self.assertEqual(result['email'],'test@example.com')
        self.assertEqual(result['windows'][0]['remainingPercent'],56)
        self.assertNotIn('SENSITIVE',json.dumps(result))
        self.assertEqual(result['status'],'connected')

    def test_expired_claude_credentials_are_not_renewed_or_returned(self):
        with patch.object(monitor,'claude_credentials',return_value={'accessToken':'PRIVATE'}),patch.object(monitor,'claude_get',side_effect=urllib.error.HTTPError('https://example.com/PRIVATE',401,'PRIVATE',None,None)):
            result=monitor.read_claude_account(self.profile(),self.root)
        self.assertEqual(result['status'],'expired')
        self.assertEqual(result['windows'],[])
        self.assertNotIn('PRIVATE',json.dumps(result))

    def test_changed_private_account_does_not_attach_quota_to_the_wrong_identity(self):
        with patch.object(monitor,'claude_credentials',return_value={'accessToken':'PRIVATE'}),patch.object(monitor,'claude_get',return_value={'account':{'email':'other@example.com'}}) as get:
            result=monitor.read_claude_account(self.profile(email='expected@example.com'),self.root)
        self.assertIsNone(result['email'])
        self.assertEqual(result['windows'],[])
        self.assertEqual(get.call_count,1)

    def test_codex_only_uses_account_read_operations_and_closes_its_own_client(self):
        reader=MagicMock()
        reader.request.side_effect=[{}, {'account':{'type':'chatgpt','email':'test@example.com','planType':'pro','secret':'PRIVATE'}},
            {'rateLimits':{'primary':{'usedPercent':8,'windowDurationMins':300},'secondary':{'usedPercent':40,'windowDurationMins':10080}}},
            {'account':{'type':'chatgpt','email':'test@example.com'}}]
        with patch.object(monitor.shutil,'which',return_value='/fixture/codex'),patch.object(monitor,'CodexReader',return_value=reader):
            result=monitor.read_codex_account(self.profile('codex',directory=str(self.root)),self.root)
        self.assertEqual([c.args[0] for c in reader.request.call_args_list],['initialize','account/read','account/rateLimits/read','account/read'])
        self.assertEqual(reader.request.call_args_list[1].args[1],{'refreshToken':False})
        reader.close.assert_called_once()
        self.assertEqual([w['remainingPercent'] for w in result['windows']],[92,60])
        self.assertNotIn('PRIVATE',json.dumps(result))

    def test_codex_account_change_during_read_discards_mismatched_quota(self):
        reader=MagicMock()
        reader.request.side_effect=[{}, {'account':{'type':'chatgpt','email':'first@example.com'}},
            {'rateLimits':{'primary':{'usedPercent':8}}}, {'account':{'type':'chatgpt','email':'second@example.com'}}]
        with patch.object(monitor.shutil,'which',return_value='/fixture/codex'),patch.object(monitor,'CodexReader',return_value=reader):
            result=monitor.read_codex_account(self.profile('codex',directory=str(self.root)),self.root)
        self.assertEqual(result['status'],'unavailable')
        self.assertIsNone(result['email'])
        self.assertEqual(result['windows'],[])

    def test_api_key_signin_does_not_request_subscription_quota(self):
        reader=MagicMock()
        reader.request.side_effect=[{}, {'account':{'type':'apiKey'}}]
        with patch.object(monitor.shutil,'which',return_value='/fixture/codex'),patch.object(monitor,'CodexReader',return_value=reader):
            result=monitor.read_codex_account(self.profile('codex',directory=str(self.root)),self.root)
        self.assertEqual(result['status'],'apiKey')
        self.assertEqual(reader.request.call_count,2)
        self.assertEqual(result['windows'],[])

    def test_only_explicit_in_home_saved_profiles_are_discovered(self):
        support=self.root/'Library/Application Support/OpenAIQuotaBar'
        support.mkdir(parents=True)
        private=self.root/'private-claude';private.mkdir()
        records=[{'connection':'claude','claudeConfigDir':str(private),'name':'Private','email':'test@example.com'},
            {'connection':'claude','claudeConfigDir':'/tmp','name':'Outside home'},
            {'connection':'codex','usesLocalCodex':True,'id':'same-default'}]
        (support/'accounts.json').write_text(json.dumps(records))
        profiles=monitor.account_profiles(self.root)
        self.assertEqual(len(profiles),3)
        self.assertEqual(profiles[-1]['directory'],str(private))

    def test_a_failed_provider_cannot_hide_other_accounts_or_expose_exception_details(self):
        with patch.object(monitor,'read_claude_account',side_effect=ValueError('PRIVATE')),patch.object(monitor,'read_codex_account',return_value={'status':'connected'}):
            results=monitor.connected_accounts(self.root)
        self.assertEqual(results[1]['status'],'connected')
        self.assertEqual(results[0]['status'],'unavailable')
        self.assertNotIn('PRIVATE',json.dumps(results))
