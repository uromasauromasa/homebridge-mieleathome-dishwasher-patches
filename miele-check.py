#!/usr/bin/env python3
# Miele食洗機で、クラウド経由（Homebridgeと同じ仕組み）で何ができるかを調べるスクリプト
# 使い方（Pi上で）: sudo python3 miele-check.py
# 何も操作はしません（読み取りだけです）。トークンは画面に表示しません。

import glob, json, urllib.request, urllib.error

BASE = 'https://api.mcs3.miele.com/v1'
TYPES = {1: '洗濯機', 2: '乾燥機', 7: '食洗機', 24: '洗濯乾燥機'}

def find_token(obj):
    if isinstance(obj, dict):
        if obj.get('access_token') and obj.get('refresh_token'):
            return obj['access_token']
        for v in obj.values():
            t = find_token(v)
            if t:
                return t
    elif isinstance(obj, list):
        for v in obj:
            t = find_token(v)
            if t:
                return t
    return None

candidates = []
for f in glob.glob('/var/lib/homebridge/**/*', recursive=True):
    if '/node_modules/' in f or '/backups/' in f:
        continue
    try:
        with open(f, encoding='utf-8') as fh:
            text = fh.read(2_000_000)
        if 'refresh_token' not in text:
            continue
        t = find_token(json.loads(text))
    except Exception:
        continue
    if t:
        # Mieleに関係するファイルを優先する
        candidates.append(('miele' not in (f + text).lower(), f, t))

token = None
if candidates:
    candidates.sort()
    _, path, token = candidates[0]
    print('トークンの保存場所:', path)

if not token:
    print('エラー: Mieleのトークンが見つかりません。Homebridgeでの認証が済んでいるか確認してください。')
    raise SystemExit(1)

def get(path):
    req = urllib.request.Request(BASE + path, headers={
        'Authorization': 'Bearer ' + token, 'Accept': 'application/json'})
    try:
        with urllib.request.urlopen(req, timeout=15) as r:
            body = r.read().decode()
            return r.status, (json.loads(body) if body else None)
    except urllib.error.HTTPError as e:
        return e.code, e.read().decode()[:300]

st, devices = get('/devices?language=en')
if st != 200:
    print('機器一覧の取得に失敗しました:', st, devices)
    raise SystemExit(1)

for serial, dev in devices.items():
    ident = dev.get('ident', {})
    t = ident.get('type', {}).get('value_raw')
    state = dev.get('state', {})
    print('=' * 60)
    print('機器:', TYPES.get(t, t), '/', ident.get('deviceName') or ident.get('type', {}).get('value_localized'))
    print('状態:', state.get('status', {}).get('value_localized'), f"(コード {state.get('status', {}).get('value_raw')})")
    print('選択中のプログラム:', state.get('ProgramID', {}).get('value_localized'))
    print('遠隔操作の設定:', json.dumps(state.get('remoteEnable'), ensure_ascii=False))
    st, actions = get(f'/devices/{serial}/actions')
    print('今できる操作 (actions):', st, json.dumps(actions, ensure_ascii=False))
    st, programs = get(f'/devices/{serial}/programs?language=en')
    print('選べるプログラム (programs):', st, json.dumps(programs, ensure_ascii=False))
print('=' * 60)
