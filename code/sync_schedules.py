#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
Sync Bubble → Supabase: tabela schedule

Busca todos os schedules do Bubble e faz upsert no Supabase usando unique_id
como chave. Registros existentes são atualizados (corrige class_id e outros
campos), registros novos são criados.

Uso:
    python sync_schedules.py                        # Sync completo
    python sync_schedules.py --dry-run              # Simula sem gravar no Supabase
    python sync_schedules.py --save-local           # Salva dados do Bubble em SQLite + sync
    python sync_schedules.py --save-local --dry-run # Salva em SQLite, não envia ao Supabase
    python sync_schedules.py --from-local           # Usa SQLite já salvo (sem buscar no Bubble)
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
# SQLite
# ---------------------------------------------------------------------------

def sqlite_save(records: List[Dict], db_path: str = SQLITE_FILE):
    """Salva os registros brutos do Bubble em SQLite (raw) e transformados."""
    conn = sqlite3.connect(db_path)
    cur = conn.cursor()

    # Tabela raw: dados exatamente como vieram do Bubble (JSON)
    cur.execute("""
        CREATE TABLE IF NOT EXISTS schedules_raw (
            bubble_id   TEXT PRIMARY KEY,
            data        TEXT NOT NULL,
            saved_at    TEXT NOT NULL
        )
    """)

    # Tabela transformada: pronta para o Supabase, fácil de consultar
    cur.execute("""
        CREATE TABLE IF NOT EXISTS schedules (
            unique_id        TEXT PRIMARY KEY,
            class_id         TEXT,
            teacher_id       TEXT,
            date             TEXT,
            duration         REAL,
            att_rate         REAL,
            presenca_anotada INTEGER,
            admin            TEXT,
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

        t = transform_schedule(record)
        if t:
            transformed_rows.append((
                t["unique_id"],
                t.get("class_id"),
                t.get("teacher_id"),
                t.get("date"),
                t.get("duration"),
                t.get("att_rate"),
                1 if t.get("presenca_anotada") else 0,
                t.get("admin"),
                saved_at,
            ))

    cur.executemany(
        "INSERT OR REPLACE INTO schedules_raw (bubble_id, data, saved_at) VALUES (?, ?, ?)",
        raw_rows
    )
    cur.executemany(
        """INSERT OR REPLACE INTO schedules
           (unique_id, class_id, teacher_id, date, duration, att_rate, presenca_anotada, admin, saved_at)
           VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)""",
        transformed_rows
    )

    conn.commit()
    conn.close()
    print(f"  SQLite: {len(raw_rows)} registros salvos em '{db_path}'")


def sqlite_load(db_path: str = SQLITE_FILE) -> List[Dict]:
    """Carrega os registros transformados do SQLite."""
    if not os.path.exists(db_path):
        print(f"  ERRO: arquivo '{db_path}' não encontrado. Rode com --save-local primeiro.")
        sys.exit(1)

    conn = sqlite3.connect(db_path)
    conn.row_factory = sqlite3.Row
    cur = conn.cursor()
    cur.execute("SELECT * FROM schedules")
    rows = [dict(row) for row in cur.fetchall()]
    conn.close()

    print(f"  SQLite: {len(rows)} registros carregados de '{db_path}'")
    return rows


# ---------------------------------------------------------------------------
# Transform
# ---------------------------------------------------------------------------

def transform_schedule(record: Dict) -> Optional[Dict]:
    """
    Mapeia um registro do Bubble para a estrutura da tabela schedule do Supabase.
    Campos confirmados via API em 2026-04-08.
    """
    unique_id = record.get("_id")
    if not unique_id:
        return None

    raw_date = record.get("date") or record.get("Date")
    if raw_date:
        raw_date = str(raw_date)[:10]

    # "professores" é uma lista no Bubble — schedule tem um único teacher_id no Supabase
    professores = record.get("professores") or []
    teacher_id = professores[0] if professores else None

    return {
        "unique_id":        unique_id,
        "class_id":         record.get("Class"),
        "teacher_id":       teacher_id,
        "date":             raw_date,
        "duration":         record.get("Duration"),
        "att_rate":         record.get("Rate"),
        "presenca_anotada": record.get("presenca_anotada") or False,
        "admin":            record.get("Admin") or "sync_script",
    }


def clean(record: Dict) -> Dict:
    """Remove campos None para não sobrescrever dados com nulo."""
    return {k: v for k, v in record.items() if v is not None}


# ---------------------------------------------------------------------------
# Sync → Supabase
# ---------------------------------------------------------------------------

def sync_to_supabase(rows: List[Dict], supabase: Client, dry_run: bool) -> Dict:
    success = 0
    failed = 0
    skipped = 0
    failed_ids = []

    # rows podem vir do Bubble (precisam de transform) ou do SQLite (já transformados)
    # Normalizamos aqui: se tem "_id" é raw do Bubble, senão já está transformado
    transformed_all = []
    for row in rows:
        if "_id" in row:
            t = transform_schedule(row)
            if not t:
                skipped += 1
                continue
            transformed_all.append(clean(t))
        else:
            # Vindo do SQLite: ajusta tipo booleano
            row["presenca_anotada"] = bool(row.get("presenca_anotada"))
            transformed_all.append(clean({k: v for k, v in row.items() if k != "saved_at" and v is not None}))

    batches = [transformed_all[i:i+BATCH_SIZE] for i in range(0, len(transformed_all), BATCH_SIZE)]
    print(f"  Enviando {len(transformed_all)} registros em {len(batches)} lote(s)...")

    for i, batch in enumerate(batches, 1):
        if dry_run:
            print(f"  [DRY RUN] Lote {i}/{len(batches)}: {len(batch)} registros (não gravado)")
            success += len(batch)
            continue

        try:
            response = supabase.table("schedule").upsert(
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
    parser = argparse.ArgumentParser(description="Sync schedules: Bubble → Supabase (upsert por unique_id)")
    parser.add_argument("--dry-run",    action="store_true", help="Simula sem gravar no Supabase")
    parser.add_argument("--save-local", action="store_true", help="Salva dados do Bubble em SQLite antes do sync")
    parser.add_argument("--from-local", action="store_true", help="Usa SQLite já salvo, sem buscar no Bubble")
    parser.add_argument("--year",       type=int, default=None, help="Filtra apenas registros do ano informado (ex: 2026)")
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
    print("  SYNC SCHEDULES: BUBBLE → SUPABASE")
    print(f"  {datetime.now().strftime('%Y-%m-%d %H:%M:%S')}")
    print("=" * 60)

    print(f"\n{'─'*60}")
    print("  SCHEDULE")
    print(f"{'─'*60}")

    supabase: Client = create_client(
        os.getenv("SUPABASE_URL"),
        os.getenv("SUPABASE_SERVICE_KEY")
    )

    if args.from_local:
        # Carrega do SQLite sem bater na API do Bubble
        rows = sqlite_load()
    else:
        bubble = BubbleAPI(
            app_name=os.getenv("BUBBLE_APP_NAME"),
            api_token=os.getenv("BUBBLE_API_TOKEN")
        )
        rows = bubble.get_all_records("Schedule")

        if not rows:
            print("  Nenhum registro encontrado no Bubble.")
            sys.exit(0)

        if args.save_local:
            sqlite_save(rows)

    if args.year:
        before = len(rows)
        rows = [r for r in rows if str(r.get("date") or r.get("Date") or "").startswith(str(args.year))]
        print(f"  Filtro --year {args.year}: {len(rows)} de {before} registros selecionados")

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
        log_file = _ROOT / "logs" / f"sync_schedules_log_{datetime.now().strftime('%Y%m%d_%H%M%S')}.json"
        with open(log_file, "w", encoding="utf-8") as f:
            json.dump({"timestamp": datetime.now().isoformat(), "result": result}, f, indent=2, ensure_ascii=False)
        print(f"\n  Log salvo em: {log_file}")

    print(f"{'='*60}\n")


if __name__ == "__main__":
    main()
