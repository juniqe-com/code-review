import json
import re
import sys

lines = sys.stdin.read().splitlines()
models = []

for index, line in enumerate(lines):
    match = re.match(r'^(\s*)(?:-\s+)?uses:\s*["\']?[a-zA-Z0-9._-]+/code-review@', line)
    if not match:
        continue
    action_indent = len(match.group(1))
    for position in range(index + 1, len(lines)):
        candidate = lines[position]
        if not candidate.strip():
            continue
        indent = len(candidate) - len(candidate.lstrip())
        with_match = re.match(r'^\s*with:\s*$', candidate)
        if indent < action_indent or (indent == action_indent and candidate.lstrip().startswith('- ')):
            break
        if not with_match:
            continue
        for field_position in range(position + 1, len(lines)):
            field = lines[field_position]
            if not field.strip():
                continue
            field_indent = len(field) - len(field.lstrip())
            if field_indent <= indent:
                break
            value_match = re.match(r'^\s*(?:models|model):\s*(.*?)\s*$', field)
            if not value_match:
                continue
            value = value_match.group(1)
            if value in ('>', '>-', '|', '|-'):
                parts = []
                for part in lines[field_position + 1:]:
                    if not part.strip():
                        continue
                    if len(part) - len(part.lstrip()) <= field_indent:
                        break
                    parts.append(part.strip())
                value = ' '.join(parts)
            value = value.strip('"\'')
            models.extend(model.strip() for model in value.split(',') if model.strip())

models = list(dict.fromkeys(models))
if not models or any(not re.fullmatch(r'[a-zA-Z0-9._-]+/[a-zA-Z0-9._-]+', model) for model in models):
    sys.exit('No literal models found in the Pi review workflow')
print(json.dumps(models))
