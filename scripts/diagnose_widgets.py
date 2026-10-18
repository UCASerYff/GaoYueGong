#!/usr/bin/env python3
"""Read-only, local widget evidence. Never opens an app, reloads widgets, or modifies the database."""
import argparse
import datetime as dt
import hashlib
import json
import pathlib
import plistlib
import sqlite3
import subprocess

ROOT = pathlib.Path(__file__).resolve().parent.parent
GROUP = pathlib.Path.home() / 'Library/Group Containers/5G96498KGJ.com.gaoseries.GaoYueGong'
EPOCH = dt.datetime(2001, 1, 1, tzinfo=dt.timezone.utc)
TZ = dt.timezone(dt.timedelta(hours=8))


def stamp(value):
    return (EPOCH + dt.timedelta(seconds=value)).astimezone(TZ).isoformat() if value is not None else None


def command(args):
    result = subprocess.run(args, capture_output=True, text=True, timeout=20)
    return {'exitCode': result.returncode, 'output': (result.stdout + result.stderr).strip()}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--output', type=pathlib.Path, help='Save private evidence locally; do not upload it.')
    args = parser.parse_args()
    result = {'observedAt': dt.datetime.now(TZ).isoformat(), 'group': str(GROUP),
              'desktopRendering': 'not observed; no UI or smoke test was performed'}
    for label, path in [('app', pathlib.Path('/Applications/搞月供.app')),
                        ('widget', pathlib.Path('/Applications/搞月供.app/Contents/PlugIns/GaoYueGongWidgets.appex'))]:
        try:
            info = plistlib.loads((path / 'Contents/Info.plist').read_bytes())
            result[label] = {'path': str(path), 'identifier': info['CFBundleIdentifier'],
                'version': info['CFBundleShortVersionString'], 'build': info['CFBundleVersion'],
                'signature': command(['codesign', '--verify', '--deep', '--strict', str(path)]),
                'entitlements': command(['codesign', '-d', '--entitlements', ':-', str(path)])}
        except Exception as error:
            result[label] = {'error': str(error)}
    result['registration'] = command(['pluginkit', '-m', '-A', '-D', '-v', '-i', 'com.gaoseries.GaoYueGong.widgets'])
    database = GROUP / 'Monthly/monthly.sqlite'
    try:
        with sqlite3.connect(database.as_uri() + '?mode=ro', uri=True, timeout=1) as connection:
            integrity = connection.execute('PRAGMA quick_check').fetchone()[0]
            raw = connection.execute('SELECT json FROM state WHERE id=1').fetchone()[0]
        if isinstance(raw, str):
            raw = raw.encode()
        state = json.loads(raw)
        result['businessDatabase'] = {'integrity': integrity, 'schema': state['schemaVersion'],
            'rules': state['rulesVersion'], 'sourceUpdatedAt': stamp(state['updatedAt']),
            'revision': hashlib.sha256(raw).hexdigest(),
            'counts': {key: len(state[key]) for key in ['subscriptions', 'payments', 'benefits', 'claims']}}
    except Exception as error:
        result['businessDatabase'] = {'error': str(error), 'counts': None}
    sync = GROUP / 'Monthly/WidgetSync'
    for name in ['pending-refresh.json', 'read-receipts.json']:
        try:
            value = json.loads((sync / name).read_text())
            if isinstance(value, list):
                value = value[-12:]
            result[name] = value
        except FileNotFoundError:
            result[name] = {'status': 'no receipt yet; not evidence of a successful refresh'}
        except Exception as error:
            result[name] = {'error': str(error)}
    result['retryMarkers'] = len(list(sync.glob('retry-*.json'))) if sync.is_dir() else None
    try:
        cache = json.loads((sync / 'last-valid-v1.json').read_text())
        result['lastValidCache'] = {key: cache[key] for key in ['formatVersion', 'sha256']}
        result['lastValidCache'].update(generatedAt=stamp(cache['generatedAt']), verifiedAt=stamp(cache['verifiedAt']))
    except FileNotFoundError:
        result['lastValidCache'] = {'status': 'not generated yet'}
    except Exception as error:
        result['lastValidCache'] = {'error': str(error)}
    text = json.dumps(result, ensure_ascii=False, indent=2)
    if args.output:
        args.output.parent.mkdir(parents=True, exist_ok=True)
        args.output.write_text(text + '\n')
        print('Private read-only evidence saved to:', args.output)
    else:
        print(text)


if __name__ == '__main__':
    main()
