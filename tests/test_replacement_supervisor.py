import importlib.util
import json
from pathlib import Path
import tempfile
import unittest

spec = importlib.util.spec_from_file_location('supervisor', Path(__file__).parents[1]/'scripts/replacement-supervisor.py')
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)


class TestSupervisor(unittest.TestCase):
    def make(self, root, phase='idle', started=False, finished=False, paired=False):
        (root/'.env').write_text('IPC_STORAGE_DIR='+str(root/'storage'))
        runner = module.Supervisor(root)
        events=[]
        state={'phase':phase,'started':started,'finished':finished,'paired':paired}
        phases={'stage':'staged','apply':'restored','activate':'activated','release':'active','started':'active','finish':'active'}
        def worker(command):
            events.append(command)
            if command=='status': return dict(state)
            state['phase']=phases[command]
            if command in {'started','finish'}:state['started' if command=='started' else 'finished']=True
            return {'phase':state['phase']}
        runner.worker=worker
        runner.run=lambda command:events.append(tuple(command))
        runner.healthy=lambda held:events.append(('healthy',held))
        return runner,events,state

    def test_order_and_retry_after_every_phase(self):
        with tempfile.TemporaryDirectory() as directory:
            root=Path(directory)
            for phase in ('idle','staged','restored','activated','active'):
                runner,events,state=self.make(root,phase)
                runner.tick()
                self.assertTrue(state['finished'])
                if phase in {'idle','staged'}:
                    self.assertLess(events.index(('stop','site-agent')),events.index('apply'))
                    self.assertLess(events.index('apply'),events.index(('healthy',True)))
                if 'activate' in events:
                    self.assertLess(events.index(('healthy',True)),events.index('activate'))
                    self.assertLess(events.index('activate'),events.index('release'))
                self.assertLess(events.index(('healthy',False)),events.index('finish'))

    def test_failed_held_readiness_never_activates(self):
        with tempfile.TemporaryDirectory() as directory:
            runner,events,state=self.make(Path(directory),'restored')
            def unhealthy(held):raise RuntimeError('not ready')
            runner.healthy=unhealthy
            with self.assertRaises(RuntimeError):runner.tick()
            self.assertNotIn('activate',events)
            self.assertEqual(state['phase'],'restored')

    def test_lost_finish_response_does_not_restart_active_control(self):
        with tempfile.TemporaryDirectory() as directory:
            runner,events,state=self.make(Path(directory),'active',started=True)
            real=runner.worker
            def outage(command):
                if command=='finish':raise RuntimeError('cloud offline')
                return real(command)
            runner.worker=outage
            for _ in range(3):
                with self.assertRaises(RuntimeError):runner.tick()
            self.assertEqual(events,['status']*3)

    def test_existing_paired_and_finished_devices_do_not_launch_containers(self):
        with tempfile.TemporaryDirectory() as directory:
            root=Path(directory)
            runner,events,_=self.make(root)
            ipc=root/'storage/ipc';ipc.mkdir(parents=True)
            (ipc/'identity.json').write_text(json.dumps({'ipc_id':'existing'}))
            runner.tick();self.assertEqual(events,[])
            (ipc/'replacement.json').write_text(json.dumps({'phase':'active','finished':True}))
            runner.tick();self.assertEqual(events,[])


if __name__=='__main__':unittest.main()
