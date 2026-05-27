#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
Sync Bubble → Supabase: tabelas programs e program_patrocinadores

Busca todos os programas do Bubble, faz upsert em programs usando unique_id
como chave, e reconstrói a program_patrocinadores a partir da lista
'patrocinadores' de cada programa.

Uso:
    python sync_programs.py                        # Sync completo
    python sync_programs.py --dry-run              # Simula sem gravar no Supabase
    python sync_programs.py --save-local           # Salva em SQLite + sync
    python sync_programs.py --save-local --dry-run
    python sync_programs.py --from-local           # Usa SQLite já salvo
"""

import os
import sys
import json
import sqlite3
import argparse
from datetime import datetime
from typing import Dict, List, Optional, Tuple
import requests
from supabase import create_client, Client
from dotenv import load_dotenv

if sys.platform == "win32":
    sys.stdout.reconfigure(encoding='utf-8')

load_dotenv()

import pathlib as _pathlib

BATCH_SIZE  = 100
_ROOT = _pathlib.Path(__file__).parent.parent  # raiz do projeto
SQLITE_FILE = str(_ROOT / "data" / "bubble_cache.db")
BUBBLE_TYPE = "programs"


# ---------------------------------------------------------------------------
# Bubble API
# ---------------------------------------------------------------------------

class BubbleAPI:
    def __init__(self, app_name: str, api_token: str):
        self.base_url = f"https://{app_name}.bubbleapps.io/api/1.1/obj"
        self.headers  = {"Authorization": f"Bearer {api_token}"}

    def get_all_records(self, data_type: str) -> List[Dict]:
        url    = f"{self.base_url}/{data_type}"
        params = {"limit": 100, "cursor": 0}
        all_results = []

        print(f"  Buscando '{data_type}' no Bubble...")

        while True:
            try:
                r = requests.get(url, headers=self.headers, params=params, timeout=30)
                r.raise_for_status()
                data    = r.json()
                results = data.get("response", {}).get("results", [])
                all_results.extend(results)

                remaining = data.get("response", {}).get("remaining", 0)
                total     = data.get("response", {}).get("count", len(all_results))
                print(f"  → {len(all_results)}/{total} registros carregados...", end="\r")

                if remaining == 0:
                    break
                params["cursor"] += len(results)

            except requests.exceptions.RequestException as e:
                print(f"\n  ERRO ao buscar página (cursor={params['cursor']}): {e}")
                break

        print(f"  → {len(all_results)} registros carregados.         ")
        return all_results


# ---------------------------------------------------------------------------
# Transform
# ---------------------------------------------------------------------------

def transform_program(record: Dict) -> Optional[Dict]:
    unique_id = record.get("_id")
    if not unique_id:
        return None

    return {
        "unique_id":           unique_id,
        "admin":               record.get("admin") or "sync_script",
        "program_name":        record.get("program_name"),
        "description":         record.get("description"),
        "cidade":              record.get("Cidade"),
        "uf":                  record.get("UF"),
        "cep":                 record.get("CEP"),
        "key_searchable":      record.get("key_searcheable") or record.get("key_searchable"),
        "ret_rate_program":    record.get("ret_rate_program"),
        "numero_endereco":     record.get("numero_endereco"),
    }


def extract_patrocinadores(records: List[Dict]) -> List[Dict]:
    """Extrai os pares program_id → sponsor_id da lista patrocinadores de cada programa."""
    rows = []
    for record in records:
        program_id    = record.get("_id")
        patrocinadores = record.get("patrocinadores") or []
        for sponsor_id in patrocinadores:
            rows.append({"program_id": program_id, "sponsor_id": sponsor_id})
    return rows


def clean(record: Dict) -> Dict:
    return {k: v for k, v in record.items() if v is not None}


# ---------------------------------------------------------------------------
# SQLite
# ---------------------------------------------------------------------------

def sqlite_save(records: List[Dict], db_path: str = SQLITE_FILE):
    conn = sqlite3.connect(db_path)
    cur  = conn.cursor()

    cur.execute("""
        CREATE TABLE IF NOT EXISTS programs_raw (
            bubble_id TEXT PRIMARY KEY,
            data      TEXT NOT NULL,
            saved_at  TEXT NOT NULL
        )
    """)

    cur.execute("""
        CREATE TABLE IF NOT EXISTS programs (
            unique_id        TEXT PRIMARY KEY,
            admin            TEXT,
            program_name     TEXT,
            description      TEXT,
            cidade           TEXT,
            uf               TEXT,
            cep              TEXT,
            key_searchable   TEXT,
            ret_rate_program REAL,
            numero_endereco  REAL,
            saved_at         TEXT NOT NULL
        )
    """)

    cur.execute("""
        CREATE TABLE IF NOT EXISTS program_patrocinadores (
            program_id TEXT NOT NULL,
            sponsor_id TEXT NOT NULL,
            PRIMARY KEY (program_id, sponsor_id)
        )
    """)

    saved_at = datetime.now().isoformat()
    raw_rows = []
    prog_rows = []
    patr_rows = []

    for record in records:
        bubble_id = record.get("_id")
        if not bubble_id:
            continue

        raw_rows.append((bubble_id, json.dumps(record, ensure_ascii=False), saved_at))

        t = transform_program(record)
        if t:
            prog_rows.append((
                t["unique_id"], t.get("admin"), t.get("program_name"),
                t.get("description"), t.get("cidade"), t.get("uf"),
                t.get("cep"), t.get("key_searchable"),
                t.get("ret_rate_program"), t.get("numero_endereco"), saved_at,
            ))

        for sponsor_id in (record.get("patrocinadores") or []):
            patr_rows.append((bubble_id, sponsor_id))

    cur.executemany(
        "INSERT OR REPLACE INTO programs_raw (bubble_id, data, saved_at) VALUES (?,?,?)",
        raw_rows
    )
    cur.executemany(
        """INSERT OR REPLACE INTO programs
           (unique_id, admin, program_name, description, cidade, uf, cep,
            key_searchable, ret_rate_program, numero_endereco, saved_at)
           VALUES (?,?,?,?,?,?,?,?,?,?,?)""",
        prog_rows
    )
    cur.execute("DELETE FROM program_patrocinadores")
    cur.executemany(
        "INSERT OR REPLACE INTO program_patrocinadores (program_id, sponsor_id) VALUES (?,?)",
        patr_rows
    )

    conn.commit()
    conn.close()
    print(f"  SQLite: {len(prog_rows)} programs, {len(patr_rows)} patrocinadores salvos em '{db_path}'")


def sqlite_load(db_path: str = SQLITE_FILE) -> List[Dict]:
    if not os.path.exists(db_path):
        print(f"  ERRO: '{db_path}' nao encontrado. Rode com --save-local primeiro.")
        sys.exit(1)

    conn = sqlite3.connect(db_path)
    conn.row_factory = sqlite3.Row
    cur  = conn.cursor()
    cur.execute("SELECT * FROM programs_raw")
    rows = [json.loads(dict(r)["data"]) for r in cur.fetchall()]
    conn.close()

    print(f"  SQLite: {len(rows)} registros carregados de '{db_path}'")
    return rows


# ---------------------------------------------------------------------------
# Sync → Supabase
# ---------------------------------------------------------------------------

def sync_programs(records: List[Dict], supabase: Client, dry_run: bool) -> Tuple[int, int]:
    transformed = [clean(t) for r in records if (t := transform_program(r))]
    batches = [transformed[i:i+BATCH_SIZE] for i in range(0, len(transformed), BATCH_SIZE)]

    print(f"  [programs] Enviando {len(transformed)} registros em {len(batches)} lote(s)...")
    success = 0

    for i, batch in enumerate(batches, 1):
        if dry_run:
            print(f"  [DRY RUN] Lote {i}/{len(batches)}: {len(batch)} registros")
            success += len(batch)
            continue
        try:
            resp = supabase.table("programs").upsert(batch, on_conflict="unique_id").execute()
            n = len(resp.data) if resp.data else 0
            success += n
            print(f"  Lote {i}/{len(batches)}: OK {n}  FALHA {len(batch)-n}")
        except Exception as e:
            print(f"  ERRO no lote {i}: {e}")

    return success, len(transformed)


def sync_patrocinadores(records: List[Dict], supabase: Client, dry_run: bool) -> Tuple[int, int]:
    rows = extract_patrocinadores(records)

    print(f"  [program_patrocinadores] Reconstruindo {len(rows)} vinculos...")

    if dry_run:
        print(f"  [DRY RUN] {len(rows)} vinculos (nao gravado)")
        return len(rows), len(rows)

    # Apaga tudo e reinserere — garante que remoções no Bubble sejam refletidas
    try:
        supabase.table("program_patrocinadores").delete().neq("program_id", "").execute()
    except Exception as e:
        print(f"  AVISO ao limpar program_patrocinadores: {e}")

    batches = [rows[i:i+BATCH_SIZE] for i in range(0, len(rows), BATCH_SIZE)]
    success = 0

    for i, batch in enumerate(batches, 1):
        try:
            resp = supabase.table("program_patrocinadores").insert(batch).execute()
            n = len(resp.data) if resp.data else 0
            success += n
        except Exception as e:
            print(f"  ERRO no lote {i}: {e}")

    print(f"  {success} vinculos inseridos")
    return success, len(rows)


# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

def main():
    parser = argparse.ArgumentParser(description="Sync programs + patrocinadores: Bubble → Supabase")
    parser.add_argument("--dry-run",    action="store_true")
    parser.add_argument("--save-local", action="store_true")
    parser.add_argument("--from-local", action="store_true")
    args = parser.parse_args()

    required = ["BUBBLE_APP_NAME", "BUBBLE_API_TOKEN", "SUPABASE_URL", "SUPABASE_SERVICE_KEY"]
    missing  = [v for v in required if not os.getenv(v)]
    if missing:
        print("Variaveis de ambiente faltando:", missing)
        sys.exit(1)

    if args.dry_run:
        print("\nMODO DRY RUN — nenhum dado sera gravado\n")

    print("=" * 60)
    print("  SYNC PROGRAMS: BUBBLE → SUPABASE")
    print(f"  {datetime.now().strftime('%Y-%m-%d %H:%M:%S')}")
    print("=" * 60)

    supabase = create_client(os.getenv("SUPABASE_URL"), os.getenv("SUPABASE_SERVICE_KEY"))

    if args.from_local:
        records = sqlite_load()
    else:
        bubble  = BubbleAPI(os.getenv("BUBBLE_APP_NAME"), os.getenv("BUBBLE_API_TOKEN"))
        records = bubble.get_all_records(BUBBLE_TYPE)
        if not records:
            print("  Nenhum registro encontrado.")
            sys.exit(0)
        if args.save_local:
            sqlite_save(records)

    print(f"\n{'─'*60}")
    ok_prog,  total_prog  = sync_programs(records, supabase, args.dry_run)
    print(f"{'─'*60}")
    ok_patr, total_patr = sync_patrocinadores(records, supabase, args.dry_run)

    print(f"\n{'='*60}")
    print("  RESUMO")
    print(f"{'='*60}")
    print(f"  programs:               {ok_prog}/{total_prog}")
    print(f"  program_patrocinadores: {ok_patr}/{total_patr}")

    if args.dry_run:
        print("\n  DRY RUN concluido — execute sem --dry-run para gravar")
    else:
        log_file = _ROOT / "logs" / f"sync_programs_log_{datetime.now().strftime('%Y%m%d_%H%M%S')}.json"
        with open(log_file, "w", encoding="utf-8") as f:
            json.dump({"timestamp": datetime.now().isoformat(),
                       "programs": ok_prog, "patrocinadores": ok_patr}, f, indent=2)
        print(f"\n  Log salvo em: {log_file}")

    print(f"{'='*60}\n")


if __name__ == "__main__":
    main()
