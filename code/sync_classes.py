#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
Sync Bubble → Supabase: tabela class

Busca todas as classes do Bubble e faz upsert no Supabase usando unique_id
como chave. Registros existentes são atualizados, novos são criados.

Uso:
    python sync_classes.py                        # Sync completo
    python sync_classes.py --dry-run              # Simula sem gravar no Supabase
    python sync_classes.py --save-local           # Salva dados do Bubble em SQLite + sync
    python sync_classes.py --save-local --dry-run # Salva em SQLite, não envia ao Supabase
    python sync_classes.py --from-local           # Usa SQLite já salvo (sem buscar no Bubble)
"""

import os
import sys
import json
import sqlite3
import argparse
from datetime import datetime
from typing import Dict, List, Optional
import requests
from supabase import create_client, Client
from dotenv import load_dotenv

if sys.platform == "win32":
    sys.stdout.reconfigure(encoding='utf-8')

load_dotenv()

import pathlib as _pathlib

BATCH_SIZE = 100
_ROOT = _pathlib.Path(__file__).parent.parent  # raiz do projeto
SQLITE_FILE = str(_ROOT / "data" / "bubble_cache.db")
BUBBLE_TYPE = "Classes"


# ---------------------------------------------------------------------------
# Bubble API
# ---------------------------------------------------------------------------

class BubbleAPI:
    def __init__(self, app_name: str, api_token: str):
        self.base_url = f"https://{app_name}.bubbleapps.io/api/1.1/obj"
        self.headers = {
            "Authorization": f"Bearer {api_token}",
            "Content-Type": "application/json"
        }

    def get_all_records(self, data_type: str) -> List[Dict]:
        url = f"{self.base_url}/{data_type}"
        params = {"limit": 100, "cursor": 0}
        all_results = []

        print(f"  Buscando '{data_type}' no Bubble...")

        while True:
            try:
                response = requests.get(url, headers=self.headers, params=params, timeout=30)
                response.raise_for_status()
                data = response.json()

                results = data.get("response", {}).get("results", [])
                all_results.extend(results)

                remaining = data.get("response", {}).get("remaining", 0)
                total = data.get("response", {}).get("count", len(all_results))
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

def parse_date(value) -> Optional[str]:
    """Extrai apenas a parte da data de um timestamp ISO do Bubble."""
    if not value:
        return None
    return str(value)[:10]


def parse_time(value) -> Optional[str]:
    """Extrai apenas HH:MM:SS de um timestamp ISO do Bubble."""
    if not value:
        return None
    # Bubble retorna horário como 1970-01-01THH:MM:SS.000Z
    try:
        return str(value)[11:19]
    except Exception:
        return None


def list_to_text(value) -> Optional[str]:
    """Converte lista do Bubble para texto (join com vírgula)."""
    if not value:
        return None
    if isinstance(value, list):
        return ", ".join(str(v) for v in value)
    return str(value)


def transform_class(record: Dict) -> Optional[Dict]:
    """
    Mapeia um registro do Bubble para a estrutura da tabela class do Supabase.
    Campos confirmados via API em 2026-04-08.
    """
    unique_id = record.get("_id")
    if not unique_id:
        return None

    return {
        "unique_id":          unique_id,
        "admin":              record.get("Admin") or "sync_script",
        "class_code":         record.get("Class Code ") or record.get("Class Code"),
        "duration":           record.get("Duration"),
        "start_date":         parse_date(record.get("Start date")),
        "end_date":           parse_date(record.get("End date")),
        "start_time":         parse_time(record.get("Start time")),
        "day_of_week_list":   list_to_text(record.get("Day of week_List")),
        "instrument_os":      list_to_text(record.get("Instrument_OS")),
        "professores":        list_to_text(record.get("professores")),
        "program":            record.get("program"),
        "retention_rate":     str(record.get("Retention Rate")) if record.get("Retention Rate") is not None else None,
        "max_students":       record.get("Max Students") or record.get("max_students"),
        "class_location":     record.get("Class Location") or record.get("class_location"),
        "ensemble":           record.get("Ensemble") or record.get("ensemble"),
        "descricao":          record.get("descricao") or record.get("Description"),
    }


def clean(record: Dict) -> Dict:
    """Remove campos None para não sobrescrever dados com nulo."""
    return {k: v for k, v in record.items() if v is not None}


# ---------------------------------------------------------------------------
# SQLite
# ---------------------------------------------------------------------------

def sqlite_save(records: List[Dict], db_path: str = SQLITE_FILE):
    conn = sqlite3.connect(db_path)
    cur = conn.cursor()

    cur.execute("""
        CREATE TABLE IF NOT EXISTS classes_raw (
            bubble_id TEXT PRIMARY KEY,
            data      TEXT NOT NULL,
            saved_at  TEXT NOT NULL
        )
    """)

    cur.execute("""
        CREATE TABLE IF NOT EXISTS classes (
            unique_id        TEXT PRIMARY KEY,
            admin            TEXT,
            class_code       TEXT,
            duration         REAL,
            start_date       TEXT,
            end_date         TEXT,
            start_time       TEXT,
            day_of_week_list TEXT,
            instrument_os    TEXT,
            professores      TEXT,
            program          TEXT,
            retention_rate   TEXT,
            max_students     INTEGER,
            class_location   TEXT,
            ensemble         TEXT,
            descricao        TEXT,
            saved_at         TEXT NOT NULL
        )
    """)

    saved_at = datetime.now().isoformat()
    raw_rows = []
    transformed_rows = []

    for record in records:
        bubble_id = record.get("_id")
        if not bubble_id:
            continue

        raw_rows.append((bubble_id, json.dumps(record, ensure_ascii=False), saved_at))

        t = transform_class(record)
        if t:
            transformed_rows.append((
                t["unique_id"], t.get("admin"), t.get("class_code"),
                t.get("duration"), t.get("start_date"), t.get("end_date"),
                t.get("start_time"), t.get("day_of_week_list"), t.get("instrument_os"),
                t.get("professores"), t.get("program"), t.get("retention_rate"),
                t.get("max_students"), t.get("class_location"), t.get("ensemble"),
                t.get("descricao"), saved_at,
            ))

    cur.executemany(
        "INSERT OR REPLACE INTO classes_raw (bubble_id, data, saved_at) VALUES (?, ?, ?)",
        raw_rows
    )
    cur.executemany(
        """INSERT OR REPLACE INTO classes
           (unique_id, admin, class_code, duration, start_date, end_date, start_time,
            day_of_week_list, instrument_os, professores, program, retention_rate,
            max_students, class_location, ensemble, descricao, saved_at)
           VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)""",
        transformed_rows
    )

    conn.commit()
    conn.close()
    print(f"  SQLite: {len(raw_rows)} registros salvos em '{db_path}'")


def sqlite_load(db_path: str = SQLITE_FILE) -> List[Dict]:
    if not os.path.exists(db_path):
        print(f"  ERRO: '{db_path}' não encontrado. Rode com --save-local primeiro.")
        sys.exit(1)

    conn = sqlite3.connect(db_path)
    conn.row_factory = sqlite3.Row
    cur = conn.cursor()
    cur.execute("SELECT * FROM classes")
    rows = [dict(row) for row in cur.fetchall()]
    conn.close()

    print(f"  SQLite: {len(rows)} registros carregados de '{db_path}'")
    return rows


# ---------------------------------------------------------------------------
# Sync → Supabase
# ---------------------------------------------------------------------------

def sync_to_supabase(rows: List[Dict], supabase: Client, dry_run: bool) -> Dict:
    success = 0
    failed = 0
    skipped = 0
    failed_ids = []

    transformed_all = []
    for row in rows:
        if "_id" in row:
            t = transform_class(row)
            if not t:
                skipped += 1
                continue
            transformed_all.append(clean(t))
        else:
            transformed_all.append(clean({k: v for k, v in row.items() if k != "saved_at" and v is not None}))

    batches = [transformed_all[i:i+BATCH_SIZE] for i in range(0, len(transformed_all), BATCH_SIZE)]
    print(f"  Enviando {len(transformed_all)} registros em {len(batches)} lote(s)...")

    for i, batch in enumerate(batches, 1):
        if dry_run:
            print(f"  [DRY RUN] Lote {i}/{len(batches)}: {len(batch)} registros (não gravado)")
            success += len(batch)
            continue

        try:
            response = supabase.table("class").upsert(
                batch,
                on_conflict="unique_id"
            ).execute()

            batch_success = len(response.data) if response.data else 0
            batch_failed = len(batch) - batch_success
            success += batch_success
            failed += batch_failed

            print(f"  Lote {i}/{len(batches)}: OK {batch_success}  FALHA {batch_failed}")

            if batch_failed > 0:
                failed_ids += [r.get("unique_id") for r in batch]

        except Exception as e:
            print(f"  ERRO no lote {i}: {e}")
            failed += len(batch)
            failed_ids += [r.get("unique_id") for r in batch]

    print(f"\n  Resultado: {success} atualizados/criados  {failed} falhas  {skipped} sem ID")

    if failed_ids:
        print(f"  IDs com falha: {failed_ids[:5]}{'...' if len(failed_ids) > 5 else ''}")

    return {"total": len(rows), "success": success, "failed": failed, "skipped": skipped}


# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

def main():
    parser = argparse.ArgumentParser(description="Sync classes: Bubble → Supabase (upsert por unique_id)")
    parser.add_argument("--dry-run",    action="store_true", help="Simula sem gravar no Supabase")
    parser.add_argument("--save-local", action="store_true", help="Salva dados do Bubble em SQLite antes do sync")
    parser.add_argument("--from-local", action="store_true", help="Usa SQLite já salvo, sem buscar no Bubble")
    args = parser.parse_args()

    required = ["BUBBLE_APP_NAME", "BUBBLE_API_TOKEN", "SUPABASE_URL", "SUPABASE_SERVICE_KEY"]
    missing = [v for v in required if not os.getenv(v)]
    if missing:
        print("Variáveis de ambiente faltando:")
        for v in missing:
            print(f"  - {v}")
        sys.exit(1)

    if args.dry_run:
        print("\nMODO DRY RUN — nenhum dado será gravado no Supabase\n")

    print("=" * 60)
    print("  SYNC CLASSES: BUBBLE → SUPABASE")
    print(f"  {datetime.now().strftime('%Y-%m-%d %H:%M:%S')}")
    print("=" * 60)

    print(f"\n{'─'*60}")
    print("  CLASS")
    print(f"{'─'*60}")

    supabase: Client = create_client(
        os.getenv("SUPABASE_URL"),
        os.getenv("SUPABASE_SERVICE_KEY")
    )

    if args.from_local:
        rows = sqlite_load()
    else:
        bubble = BubbleAPI(
            app_name=os.getenv("BUBBLE_APP_NAME"),
            api_token=os.getenv("BUBBLE_API_TOKEN")
        )
        rows = bubble.get_all_records(BUBBLE_TYPE)

        if not rows:
            print("  Nenhum registro encontrado no Bubble.")
            sys.exit(0)

        if args.save_local:
            sqlite_save(rows)

    result = sync_to_supabase(rows, supabase, dry_run=args.dry_run)

    print(f"\n{'='*60}")
    print("  RESUMO")
    print(f"{'='*60}")
    print(f"  Total:               {result['total']}")
    print(f"  Atualizados/criados: {result['success']}")
    print(f"  Falhas:              {result['failed']}")
    print(f"  Sem ID (ignorados):  {result['skipped']}")
    if args.save_local:
        print(f"  SQLite:              {SQLITE_FILE}")

    if args.dry_run:
        print("\n  DRY RUN concluido — execute sem --dry-run para gravar")
    elif result["success"] > 0:
        log_file = _ROOT / "logs" / f"sync_classes_log_{datetime.now().strftime('%Y%m%d_%H%M%S')}.json"
        with open(log_file, "w", encoding="utf-8") as f:
            json.dump({"timestamp": datetime.now().isoformat(), "result": result}, f, indent=2, ensure_ascii=False)
        print(f"\n  Log salvo em: {log_file}")

    print(f"{'='*60}\n")


if __name__ == "__main__":
    main()
