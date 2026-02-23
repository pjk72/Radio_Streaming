import re
import os

langs_to_add = {
    'en': {
        'russian': 'Russian',
        'portuguese': 'Portuguese',
        'chinese': 'Chinese'
    },
    'it': {
        'russian': 'Russo',
        'portuguese': 'Portoghese',
        'chinese': 'Cinese'
    },
    'es': {
        'russian': 'Ruso',
        'portuguese': 'Portugués',
        'chinese': 'Chino'
    },
    'fr': {
        'russian': 'Russe',
        'portuguese': 'Portugais',
        'chinese': 'Chinois'
    },
    'de': {
        'russian': 'Russisch',
        'portuguese': 'Portugiesisch',
        'chinese': 'Chinesisch'
    }
}

base_dir = r"c:\Apps\AntigravityProject\Radio_Streaming\lib\l10n"

for lang, kv in langs_to_add.items():
    filepath = os.path.join(base_dir, f"{lang}.dart")
    if not os.path.exists(filepath):
        continue
    
    with open(filepath, 'r', encoding='utf-8') as f:
        content = f.read()

    # insert right after 'german': '...'
    insertion = []
    for k, v in kv.items():
        if f"'{k}'" not in content:
            insertion.append(f"  '{k}': '{v}',")
    
    if insertion:
        pattern = re.compile(r"(\s*'german'\s*:\s*'.*?'\s*,)")
        if pattern.search(content):
            content = pattern.sub(r"\g<1>\n" + '\n'.join(insertion), content)
            with open(filepath, 'w', encoding='utf-8') as f:
                f.write(content)
            print(f"Updated {lang}.dart")
        else:
            print(f"Key 'german' not found in {lang}.dart")
    else:
        print(f"No changes needed for {lang}.dart")
