# 두 구현의 중간 상태까지 비교한다. 실제 홈과 네트워크는 사용하지 않는다.
import hashlib, json, os, pathlib, shutil, subprocess, sys, tempfile
ROOT = pathlib.Path(__file__).resolve().parent.parent
RUST = ROOT / 'core/target/debug/mdemo-golden'
SWIFT = pathlib.Path(os.environ.get('MDEMO_GOLDEN_SWIFT', ROOT / 'Scripts/golden-run-swift.sh'))
IDS = ['01ARZ3NDEKTSV4RRFFQ69G5F%02d' % n for n in range(20)]
TIME = 1700000000

def document(id, body, modified='2023-11-14T22:13:20.000Z', locked=False):
    return (f'---\nschemaVersion: 3\nid: {id}\ncolor: "#FFF2A6"\nbgAlpha: 0.95\ntextAlpha: 1\nopen: true\npinned: true\ncreated: 2023-11-14T22:13:20.000Z\nmodified: {modified}\n' + ('locked: true\nlockVersion: 1\nlockSalt: "fake"\nlockIterations: 2000000\nlockFailures: 0\n' if locked else '') + f'---\n{body}').encode()

def snapshot(root):
    result = {}
    for p in sorted(root.rglob('*')):
        name = p.relative_to(root).as_posix()
        if p.is_dir():
            if name.startswith(('A/','B/')): result[name+'/']=b''
            continue
        if not p.is_file() or p.name in ('op.json',): continue
        data = p.read_bytes()
        if p.suffix == '.json':
            value = json.loads(data)
            if p.name == 'drive.json':
                # 호출 순서는 Set 순서와 무관한 요청 집합으로 비교한다.
                value['uploaded_paths'].sort(); value['deleted_paths'].sort()
            data = value
        result[name] = data
    return result

def execute(root, op, impl):
    file = root / 'op.json'; file.write_text(json.dumps(op))
    cmd = [str(SWIFT if impl == 'S' else RUST), 'sync-step', str(file), str(root)]
    environment = os.environ.copy()
    environment['CFFIXED_USER_HOME'] = str(root/'home')
    (root/'home').mkdir(exist_ok=True)
    result = subprocess.run(cmd, stdout=subprocess.PIPE, stderr=subprocess.PIPE, env=environment)
    if result.returncode: raise RuntimeError(f'{impl} {op}:\n{result.stdout.decode()}\n{result.stderr.decode()}')

def fix_times(root, before, step):
    # 새로 기록된 파일의 시각만 고정한다. 바뀌지 않은 파일은 그대로 둔다.
    for p in root.rglob('*'):
        if p.is_file() and p.name not in ('op.json',):
            key = p.relative_to(root).as_posix()
            data = p.read_bytes()
            if before.get(key) != data: os.utime(p, (TIME+step, TIME+step))

def setup(root, op):
    device = op.get('device','A'); data = root/device/'Data'
    id = IDS[op.get('id',0)]
    action = op['action']
    if action in ('create','edit','locked'):
        p=data/'memos'/id/'memo.md'; p.parent.mkdir(parents=True,exist_ok=True)
        p.write_bytes(document(id,op.get('body','메모'),op.get('modified','2023-11-14T22:13:20.000Z'),action=='locked'))
    elif action == 'attachment':
        p=data/'memos'/id/'attachments'/'한글.png';p.parent.mkdir(parents=True,exist_ok=True);p.write_bytes(bytes(range(256)))
    elif action == 'trash':
        p=data/'trash'/id;p.parent.mkdir(parents=True,exist_ok=True);shutil.move(str(data/'memos'/id),p)
    elif action == 'destroy':
        (data/'destroyed.json').write_text(json.dumps([id]))
    elif action == 'localOnly':
        (data/'local-only.json').write_text(json.dumps([id]))
    elif action == 'remove': shutil.rmtree(data/'trash'/id)
    elif action == 'driveRemove':
        file=root/'drive.json';drive=json.loads(file.read_text())
        for key,record in list(drive['files'].items()):
            if record['name'] == 'memo.md':
                parent=drive['files'][record['parents'][0]]
                if parent['name']==id:
                    del drive['files'][key];drive['contents'].pop(key,None)
        file.write_text(json.dumps(drive))
    elif action == 'assert':
        for rel in op.get('exists',[]): assert (root/rel.format(id=id)).exists(), rel
        for rel in op.get('absent',[]): assert not (root/rel.format(id=id)).exists(), rel
        if 'deletes' in op: assert len(json.loads((root/'drive.json').read_text())['deleted_paths']) == op['deletes']
        if 'uploadAbsent' in op:
            paths=json.loads((root/'drive.json').read_text())['uploaded_paths'];assert not any(id in p for p in paths),paths
    else: raise RuntimeError(action)

def run_scenario(file):
    scenario=json.loads(file.read_text()); traces=[]
    for combo in ('SS','RR','SR','RS'):
        with tempfile.TemporaryDirectory(prefix='mdemo-sync-') as temp:
            root=pathlib.Path(temp); (root/'home').mkdir()
            for d in ('A','B'):
                for f in ('memos','trash'): (root/d/'Data'/f).mkdir(parents=True)
            trace=[]
            for step,op in enumerate(scenario['operations']):
                before={p.relative_to(root).as_posix():p.read_bytes() for p in root.rglob('*') if p.is_file()}
                mtimes={p.relative_to(root).as_posix():p.stat().st_mtime_ns for p in root.rglob('memo.md')}
                if op['action'] in ('sync','boundaries'):
                    value=dict(op);value['ids']=[IDS[n] for n in op.get('ids',[10,11,12])]
                    execute(root,value,combo[0 if op.get('device','A')=='A' else 1])
                    if op.get('expectError') and any(f.startswith(('list','download')) for f in op.get('failures',[])):
                        for rel,content in before.items():
                            if rel.startswith(('A/','B/')): assert (root/rel).read_bytes()==content, f'실패 회차의 파일 변경: {rel}'
                        previous=json.loads(before['drive.json'])['deleted_paths']
                        assert json.loads((root/'drive.json').read_text())['deleted_paths']==previous, '실패 회차의 삭제 요청'
                    if op.get('noRewrite'):
                        for rel,time in mtimes.items(): assert (root/rel).stat().st_mtime_ns==time, f'다시 씀: {rel}'
                else: setup(root,op)
                fix_times(root,before,step)
                trace.append(snapshot(root))
            traces.append(trace)
    reference=traces[0]
    for combo,trace in zip(('RR','SR','RS'),traces[1:]):
        for step,(left,right) in enumerate(zip(reference,trace)):
            differences=[k for k in sorted(left.keys()|right.keys()) if left.get(k)!=right.get(k)]
            if differences:
                for k in differences[:4]: print(f'차이 {file.name} {combo} {step+1} {k}\nSwift: {left.get(k)!r}\n상대: {right.get(k)!r}')
                raise AssertionError('교차 시나리오 차이')
    print(f'✓ {file.stem}: SS · RR · SR · RS, {len(reference)}단계 일치',flush=True)

def state_cross():
    for first,second in ('SR','RS'):
        with tempfile.TemporaryDirectory(prefix='mdemo-state-cross-') as temp:
            root=pathlib.Path(temp);directory=root/'A';directory.mkdir()
            (root/'home').mkdir()
            dates={IDS[n]: 123.25+n/8 for n in range(20)}
            hashes={key:{'date':date,'hashes':[hashlib.sha256(key.encode()).hexdigest(), 'other/'+key]} for key,date in dates.items()}
            (directory/'sync-state-google.json').write_text(json.dumps(dates))
            (directory/'sync-state-google.hashes.json').write_text(json.dumps(hashes))
            for impl in (first,second):
                execute(root,dict(action='state',device='A'),impl)
                assert json.loads((directory/'sync-state-google.json').read_text())==dates
                assert json.loads((directory/'sync-state-google.hashes.json').read_text())==hashes
    print('✓ 상태 쌍 S→R · R→S: 지문 20/20 복원',flush=True)

if __name__=='__main__':
    if len(sys.argv)>1 and sys.argv[1] not in ('quick','full'): raise SystemExit('사용법: sync-check.sh [quick|full]')
    state_cross()
    files=sorted((ROOT/'golden/sync-scenarios').glob('*.json'))
    if len(sys.argv)>1 and sys.argv[1]=='full': files+=sorted((ROOT/'golden/sync-scenarios/full').glob('*.json'))
    for file in files: run_scenario(file)
