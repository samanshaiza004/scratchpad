#!/usr/bin/env python3
"""Compare frontend authoring with a Git revision, without counting generated code.

Usage: python3 tools/measure_alicorn_authoring.py --base b32cdcd --out report.json
The counts describe source, not runtime performance or human usability.
"""

import argparse
import json
from pathlib import Path
import re
import subprocess


def code_mask(source):
    """Preserve offsets/newlines while masking Odin comments and string contents."""
    result = list(source)
    i = 0
    while i < len(source):
        start = i
        if source.startswith('//', i):
            end = source.find('\n', i)
            i = len(source) if end < 0 else end
        elif source.startswith('/*', i):
            depth = 1
            i += 2
            while i < len(source) and depth:
                if source.startswith('/*', i):
                    depth += 1
                    i += 2
                elif source.startswith('*/', i):
                    depth -= 1
                    i += 2
                else:
                    i += 1
        elif source[i] in ('"', '`', "'"):
            quote = source[i]
            i += 1
            while i < len(source):
                if source[i] == '\\' and quote != '`':
                    i += 2
                elif source[i] == quote:
                    i += 1
                    break
                else:
                    i += 1
        else:
            i += 1
            continue
        for j in range(start, min(i, len(source))):
            if result[j] != '\n':
                result[j] = ' '
    return ''.join(result)


def metrics(source):
    code = code_mask(source)
    calls = re.findall(r'\b(alicorn|gui)\.(\w+)\s*\(', code)
    return {
        'lines': len(source.splitlines()),
        'code_lines': sum(bool(line.strip()) for line in code.splitlines()),
        'bytes': len(source.encode()),
        'layout_style_expressions': sum(name == 'layout_style' for _, name in calls),
        'explicit_container_ends': sum(package == 'alicorn' and name == 'container_end' for package, name in calls),
        'explicit_scope_ends': sum(package == 'alicorn' and name.endswith('_end') for package, name in calls),
        'runtime_text_button_calls': sum(package == 'alicorn' and name in ('text', 'button') for package, name in calls),
        'ui_calls': sum(package == 'gui' for package, _ in calls),
        'key_string_calls': sum(name == 'key_string' for _, name in calls),
        'lines_over_160_columns': sum(len(line.expandtabs(4)) > 160 for line in source.splitlines()),
    }


def procedure(source, name):
    masked = code_mask(source)
    match = re.search(r'\b' + re.escape(name) + r'\s*::\s*proc\b', masked)
    if not match:
        raise ValueError(f'Procedure not found: {name}')
    start = masked.find('{', match.end())
    depth = 1
    end = start + 1
    while depth and end < len(masked):
        if masked[end] == '{':
            depth += 1
        elif masked[end] == '}':
            depth -= 1
        end += 1
    return source[match.start():end]


def add_counts(records):
    records = list(records)
    return {key: sum(record[key] for record in records) for key in metrics('')}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--base', required=True)
    parser.add_argument('--out', type=Path)
    args = parser.parse_args()
    root = Path(__file__).resolve().parent.parent
    baseline = subprocess.check_output(['git', 'rev-parse', args.base], cwd=root, text=True).strip()
    baseline_paths = set(subprocess.check_output(
        ['git', 'ls-tree', '-r', '--name-only', baseline, 'frontends/alicorn'],
        cwd=root, text=True).splitlines())
    current_paths = {str(path.relative_to(root)) for path in (root / 'frontends/alicorn').glob('*.odin')}
    files = {}
    for path in sorted(baseline_paths | current_paths):
        relative = Path(path)
        if len(relative.parts) != 3 or relative.suffix != '.odin' or relative.name.endswith('_test.odin') or '_generated' in relative.name:
            continue
        before = subprocess.check_output(['git', 'show', f'{baseline}:{path}'], cwd=root, text=True) if path in baseline_paths else ''
        after = (root / path).read_text() if (root / path).exists() else ''
        files[path] = {'before': metrics(before), 'after': metrics(after)}
    changed = {path: values for path, values in files.items() if values['before'] != values['after']}
    scenes = {}
    for path, name in [
        ('settings_surface.odin', 'settings_surface_build'),
        ('settings_surface.odin', 'settings_page_build'),
        ('app_editor_view.odin', 'build_document_status'),
        ('workbench_surface.odin', 'build_start_screen'),
        ('app_layout.odin', 'build_app'),
    ]:
        relative = 'frontends/alicorn/' + path
        before = subprocess.check_output(['git', 'show', f'{baseline}:{relative}'], cwd=root, text=True)
        after = (root / relative).read_text()
        scenes[name] = {'before': metrics(procedure(before, name)), 'after': metrics(procedure(after, name))}
    result = {
        'baseline_revision': baseline,
        'alicorn_pin': json.loads((root / 'dependencies.lock.json').read_text())['alicorn']['revision'],
        'definitions': {
            'scope': 'Top-level production frontend Odin files; tests, generated themes, and the Caliber bridge excluded.',
            'code_lines': 'Nonblank physical lines after masking comments and string contents; not a semantic complexity score.',
            'changed_files': 'Files whose measured source counts changed. Includes imports and lexical scope braces.',
            'runtime': 'Runtime measurements are collected separately by ui_dogfood_test.odin.',
        },
        'all_frontend': {side: add_counts(value[side] for value in files.values()) for side in ('before', 'after')},
        'migrated_files': {side: add_counts(value[side] for value in changed.values()) for side in ('before', 'after')},
        'scenes': scenes,
        'files': changed,
    }
    output = json.dumps(result, indent=2) + '\n'
    if args.out:
        args.out.parent.mkdir(parents=True, exist_ok=True)
        args.out.write_text(output)
    print(output, end='')


if __name__ == '__main__':
    main()
