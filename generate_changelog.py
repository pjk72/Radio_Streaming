#!/usr/bin/env python3
"""
generate_changelog.py

Genera automaticamente CHANGELOG.md analizzando la storia Git del progetto
e utilizzando un modello AI per classificare e riassumere le modifiche.

Uso:

    python generate_changelog.py

Oppure:

    python generate_changelog.py --from v1.0.0 --to v1.6.0

Requisiti:

    pip install openai

Variabile ambiente:

    OPENAI_API_KEY=la_tua_chiave

Lo script:
- legge tag/release Git
- confronta una versione con la precedente
- analizza commit e diff
- chiede all'AI di classificare le modifiche
- genera CHANGELOG.md
"""

from __future__ import annotations

import argparse
import os
import re
import subprocess
import sys
from dataclasses import dataclass
from pathlib import Path
from typing import List, Optional

try:
    from openai import OpenAI
except ImportError:
    print("Errore: installa il pacchetto openai:")
    print("    pip install openai")
    sys.exit(1)


# ============================================================
# CONFIGURAZIONE
# ============================================================

DEFAULT_MODEL = os.getenv("CHANGELOG_AI_MODEL", "gpt-5.6")

OUTPUT_FILE = "CHANGELOG.md"

# Limite approssimativo del diff inviato al modello.
# Serve per evitare richieste enormi quando una release contiene
# moltissime modifiche.
MAX_DIFF_CHARS = 120_000

# Branch principale utilizzato come fallback
DEFAULT_BRANCH = "main"


# ============================================================
# DATA STRUCTURES
# ============================================================

@dataclass
class Release:
    tag: str
    date: str
    previous_tag: Optional[str]


# ============================================================
# GIT
# ============================================================

def run_git(*args: str) -> str:
    """Esegue un comando git e restituisce l'output."""

    result = subprocess.run(
        ["git", *args],
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
        encoding="utf-8",
        errors="replace",
    )

    if result.returncode != 0:
        raise RuntimeError(
            f"Git command failed:\n"
            f"git {' '.join(args)}\n\n"
            f"{result.stderr}"
        )

    return result.stdout.strip()


def check_git_repository() -> None:
    """Verifica che la directory corrente sia un repository Git."""

    try:
        run_git("rev-parse", "--show-toplevel")
    except RuntimeError:
        print("Errore: questa cartella non è un repository Git.")
        print("Esegui lo script dalla cartella principale del progetto.")
        sys.exit(1)


def get_tags() -> List[str]:
    """
    Restituisce i tag ordinati cronologicamente.

    Vengono ignorati tag che non sembrano versioni.
    """

    output = run_git(
        "for-each-ref",
        "--sort=creatordate",
        "--format=%(refname:short)",
        "refs/tags",
    )

    tags = []

    for tag in output.splitlines():
        tag = tag.strip()

        if not tag:
            continue

        # Accetta:
        # v1.0.0
        # 1.0.0
        # v1.5
        # 1.6
        if re.match(r"^v?\d+(?:\.\d+){1,3}(?:[-+].*)?$", tag):
            tags.append(tag)

    return tags


def get_tag_date(tag: str) -> str:
    """Restituisce la data del tag."""

    try:
        return run_git(
            "log",
            "-1",
            "--format=%ad",
            "--date=format:%Y-%m-%d",
            tag,
        )
    except RuntimeError:
        return ""


def get_commits(previous: Optional[str], current: str) -> str:
    """Restituisce la lista dei commit tra due release."""

    if previous:
        range_spec = f"{previous}..{current}"
        return run_git(
            "log",
            range_spec,
            "--pretty=format:%h | %ad | %an | %s",
            "--date=format:%Y-%m-%d",
        )

    return run_git(
        "log",
        current,
        "--pretty=format:%h | %ad | %an | %s",
        "--date=format:%Y-%m-%d",
    )


def get_diff(previous: Optional[str], current: str) -> str:
    """
    Restituisce il diff tra due release.

    Include:
    - file modificati
    - statistiche
    - contenuto del diff
    """

    if previous:
        diff = run_git(
            "diff",
            "--stat",
            previous,
            current,
        )

        diff += "\n\n"

        diff += run_git(
            "diff",
            "--no-ext-diff",
            previous,
            current,
        )
    else:
        diff = run_git(
            "show",
            "--stat",
            current,
        )

    if len(diff) > MAX_DIFF_CHARS:
        diff = (
            diff[:MAX_DIFF_CHARS]
            + "\n\n"
            "[DIFF TRUNCATED BY generate_changelog.py]"
        )

    return diff


# ============================================================
# VERSION DETECTION
# ============================================================

def normalize_version(tag: str) -> str:
    """Converte v1.2.3 in 1.2.3."""

    return tag[1:] if tag.startswith("v") else tag


def releases_from_tags(tags: List[str]) -> List[Release]:
    """Costruisce l'elenco delle release."""

    releases = []

    previous = None

    for tag in tags:
        releases.append(
            Release(
                tag=tag,
                date=get_tag_date(tag),
                previous_tag=previous,
            )
        )

        previous = tag

    return releases


# ============================================================
# AI
# ============================================================

SYSTEM_PROMPT = """
Sei un software engineer senior specializzato nell'analisi di repository Git.

Il tuo compito è analizzare commit e diff di un progetto Flutter/Dart e
generare una sezione di CHANGELOG.md comprensibile anche da un utente finale.

IMPORTANTE:

1. Non elencare semplicemente i commit.
2. Raggruppa modifiche correlate.
3. Ignora modifiche puramente interne se non hanno impatto significativo.
4. Non inventare funzionalità.
5. Se una modifica è tecnica ma importante, inseriscila nella categoria tecnica.
6. Cerca di capire l'effetto reale della modifica analizzando il codice.
7. Usa un linguaggio chiaro e professionale.
8. Evita dettagli inutilmente tecnici nella categoria Added/Changed/Fixed.
9. Mantieni i nomi tecnici quando sono importanti.

Categorie consentite:

### ✨ Added
Nuove funzionalità.

### 🐛 Fixed
Bug e problemi risolti.

### 🎨 UI/UX
Modifiche all'interfaccia e all'esperienza utente.

### ⚡ Improved
Miglioramenti a funzionalità esistenti, performance o comportamento.

### 🔧 Technical
Modifiche interne, dipendenze, architettura, configurazione,
Firebase, Android, build system ecc.

Regole:

- Non creare categorie diverse da quelle indicate.
- Non inserire categorie vuote.
- Non duplicare la stessa modifica.
- Usa bullet point.
- Massimo 8 bullet per categoria.
- Se non ci sono modifiche significative in una categoria, omettila.

Restituisci SOLO Markdown.
Non aggiungere spiegazioni prima o dopo.
"""


def create_ai_client() -> OpenAI:
    """Crea il client OpenAI."""

    api_key = os.getenv("OPENAI_API_KEY")

    if not api_key:
        print(
            "Errore: la variabile OPENAI_API_KEY non è configurata.\n\n"
            "Windows PowerShell:\n"
            "    $env:OPENAI_API_KEY='la_tua_chiave'\n\n"
            "Windows CMD:\n"
            "    set OPENAI_API_KEY=la_tua_chiave"
        )

        sys.exit(1)

    return OpenAI(api_key=api_key)


def generate_release_notes(
    client: OpenAI,
    release: Release,
    commits: str,
    diff: str,
) -> str:
    """Genera le release notes usando AI."""

    previous = release.previous_tag or "prima versione"

    user_prompt = f"""
Analizza questa release del progetto Flutter.

VERSIONE:
{normalize_version(release.tag)}

DATA:
{release.date}

VERSIONE PRECEDENTE:
{previous}

==================================================
COMMIT
==================================================

{commits}

==================================================
DIFF DEL CODICE
==================================================

{diff}

==================================================

Genera la sezione CHANGELOG relativa esclusivamente a questa release.

IMPORTANTE:
Il diff del codice ha priorità sui messaggi dei commit quando i due
non coincidono.

Non inventare funzionalità che non risultano dal codice.
"""

    response = client.responses.create(
        model=DEFAULT_MODEL,
        instructions=SYSTEM_PROMPT,
        input=user_prompt,
    )

    return response.output_text.strip()


# ============================================================
# CHANGELOG
# ============================================================

def build_changelog(
    client: OpenAI,
    releases: List[Release],
) -> str:

    sections = []

    # Dal più recente al più vecchio
    for release in reversed(releases):

        print(
            f"Analizzo {release.tag}"
            + (
                f" (da {release.previous_tag})"
                if release.previous_tag
                else ""
            )
        )

        commits = get_commits(
            release.previous_tag,
            release.tag,
        )

        diff = get_diff(
            release.previous_tag,
            release.tag,
        )

        notes = generate_release_notes(
            client,
            release,
            commits,
            diff,
        )

        version = normalize_version(release.tag)

        section = f"## [{version}] - {release.date}\n\n{notes}"

        sections.append(section)

    return (
        "# Changelog\n\n"
        "Tutte le modifiche significative del progetto "
        "sono documentate in questo file.\n\n"
        + "\n\n".join(sections)
        + "\n"
    )


def write_changelog(content: str) -> None:
    """Scrive CHANGELOG.md."""

    path = Path(OUTPUT_FILE)

    path.write_text(
        content,
        encoding="utf-8",
    )

    print()
    print(f"CHANGELOG generato: {path.resolve()}")


# ============================================================
# ARGUMENTS
# ============================================================

def parse_arguments():
    parser = argparse.ArgumentParser(
        description="Genera automaticamente CHANGELOG.md usando AI."
    )

    parser.add_argument(
        "--from",
        dest="from_version",
        help="Versione/tag iniziale, es. v1.0.0",
    )

    parser.add_argument(
        "--to",
        dest="to_version",
        help="Versione/tag finale, es. v1.6.0",
    )

    parser.add_argument(
        "--model",
        default=DEFAULT_MODEL,
        help=f"Modello AI da utilizzare (default: {DEFAULT_MODEL})",
    )

    return parser.parse_args()


# ============================================================
# MAIN
# ============================================================

def main():

    args = parse_arguments()

    global DEFAULT_MODEL
    DEFAULT_MODEL = args.model

    print("=" * 60)
    print("AI CHANGELOG GENERATOR")
    print("=" * 60)
    print()

    check_git_repository()

    tags = get_tags()

    if not tags:
        print("Nessun tag/versione trovato nel repository.")
        print()
        print(
            "Crea almeno un tag, ad esempio:"
        )
        print(
            "    git tag v1.0.0"
        )
        print(
            "    git push origin v1.0.0"
        )
        sys.exit(1)

    print(f"Trovati {len(tags)} tag versione:")
    print()

    for tag in tags:
        print(f"  • {tag}")

    print()

    releases = releases_from_tags(tags)

    # --------------------------------------------------------
    # Filtro --from
    # --------------------------------------------------------

    if args.from_version:

        start_index = None

        for i, release in enumerate(releases):

            if release.tag == args.from_version:
                start_index = i
                break

        if start_index is None:
            print(
                f"Versione non trovata: {args.from_version}"
            )
            sys.exit(1)

        releases = releases[start_index:]

    # --------------------------------------------------------
    # Filtro --to
    # --------------------------------------------------------

    if args.to_version:

        end_index = None

        for i, release in enumerate(releases):

            if release.tag == args.to_version:
                end_index = i
                break

        if end_index is None:
            print(
                f"Versione non trovata: {args.to_version}"
            )
            sys.exit(1)

        releases = releases[: end_index + 1]

    if not releases:
        print("Nessuna release da analizzare.")
        sys.exit(1)

    # --------------------------------------------------------
    # AI
    # --------------------------------------------------------

    client = create_ai_client()

    # --------------------------------------------------------
    # Generate
    # --------------------------------------------------------

    changelog = build_changelog(
        client,
        releases,
    )

    write_changelog(changelog)

    print()
    print("Operazione completata.")


if __name__ == "__main__":
    main()