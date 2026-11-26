# ZIP 컨테이너의 시각과 압축 바이트 대신 풀린 트리와 파일 내용으로 비교한다.
import json, os, pathlib, tempfile, zipfile
import importlib.util
spec = importlib.util.spec_from_file_location('sync_check', pathlib.Path(__file__).with_name('sync-check.py'))
s = importlib.util.module_from_spec(spec)
spec.loader.exec_module(s)

def tree(root):
    return {p.relative_to(root).as_posix()+('/' if p.is_dir() else ''): (p.read_bytes() if p.is_file() else None) for p in root.rglob('*')}

def zip_tree(path):
    with zipfile.ZipFile(path) as z:
        def name(info):
            if info.flag_bits & 0x800: return info.filename
            try: return info.filename.encode('cp437').decode('utf8')
            except (UnicodeEncodeError,UnicodeDecodeError): return info.filename
        return {name(info):(None if info.is_dir() else z.read(info)) for info in z.infolist() if '__MACOSX' not in pathlib.PurePosixPath(name(info)).parts}

with tempfile.TemporaryDirectory(prefix='mdemo-backup-check-') as temp:
    root=pathlib.Path(temp);(root/'home').mkdir()
    for impl in ('S','R'):
        for f in ('memos','trash'): (root/impl/'Data'/f).mkdir(parents=True)
        for action in ('create','attachment'):
            s.setup(root,dict(action=action,device=impl))
        s.setup(root,dict(action='locked',device=impl,id=1))
        s.setup(root,dict(action='create',device=impl,id=2))
        s.setup(root,dict(action='localOnly',device=impl,id=2))
        (root/impl/'Data'/'memos'/s.IDS[0]/'.hidden').write_bytes(b'hidden attachment')
        (root/impl/'Data'/'memos'/s.IDS[0]/'attachments'/'empty').mkdir()
        (root/impl/'Data'/'groups.json').write_text('["백업"]')
        (root/impl/'Data'/'board.json').write_text('{"placements":{}}')
        s.execute(root,dict(action='export',device=impl,archive=impl+'.zip'),impl)
        assert json.loads((root/'result.json').read_text())==2
    left,right=zip_tree(root/'S.zip'),zip_tree(root/'R.zip')
    for name in sorted(left.keys()|right.keys()):
        if left.get(name)!=right.get(name): print(f'백업 차이 {name}: {left.get(name)!r} / {right.get(name)!r}')
    assert left==right, '백업 트리 또는 내용 차이'
    print('✓ Swift ditto · Rust ZIP: 숨김 첨부 포함 트리와 내용 일치, 잠김 · 로컬 전용 제외',flush=True)
    outputs=[]
    for producer,consumer in (('S','S'),('R','R'),('S','R'),('R','S')):
        device=producer+consumer
        s.execute(root,dict(action='import',device=device,archive=producer+'.zip',replace=True),consumer)
        outputs.append(tree(root/device/'Data'))
    assert all(x==outputs[0] for x in outputs), '상호 가져오기 차이'
    print('✓ 백업 SS · RR · SR · RS 가져오기 일치',flush=True)
    for consumer in ('S','R'):
        device='destroy-'+consumer
        s.setup(root,dict(action='create',device=device))
        s.setup(root,dict(action='destroy',device=device))
        s.execute(root,dict(action='import',device=device,archive='S.zip',replace=False),consumer)
        assert json.loads((root/'result.json').read_text())==1
        assert not (root/device/'Data'/'memos'/s.IDS[0]).exists()
    print('✓ 양쪽 가져오기: 기존 파기 ID 복원 거부',flush=True)
    # 교체에도 기존 암호문과 백업 제외 표시가 유지되는지 양쪽 구현을 확인한다.
    for consumer in ('S','R'):
        device='locked-'+consumer
        s.setup(root,dict(action='locked',device=device,id=1))
        before=(root/device/'Data'/'memos'/s.IDS[1]/'memo.md').read_bytes()
        s.execute(root,dict(action='import',device=device,archive='R.zip',replace=True),consumer)
        assert (root/device/'Data'/'memos'/s.IDS[1]/'memo.md').read_bytes()==before
        if hasattr(os,'getxattr'):
            assert os.getxattr(root/device/'Data'/'memos'/s.IDS[1],'com.apple.metadata:com_apple_backup_excludeItem')
    print('✓ 교체 가져오기: 기존 암호문 · 백업 제외 표시 보존',flush=True)
