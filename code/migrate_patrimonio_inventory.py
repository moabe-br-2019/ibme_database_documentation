#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
Migração única: Bubble → Supabase
Tabelas: Patrimonio e Inventory

Executa apenas uma vez para popular o banco com os dados existentes no Bubble.
Após isso, a sincronização contínua será feita pelo próprio Bubble via webhook/workflow.

Uso:
    python migrate_patrimonio_inventory.py
    python migrate_patrimonio_inventory.py --dry-run   # Simula sem gravar
"""

import os
import sys
import json
import argparse
from datetime import datetime
from typing import Dict, List, Optional
import requests
from supabase import create_client, Client
from dotenv import load_dotenv

# UTF-8 no Windows
if sys.platform == "win32":
    sys.stdout.reconfigure(encoding='utf-8')

load_dotenv()

# Mapeamento dos valores do option set Condition do Bubble → enum do Supabase
# Ajuste os valores da esquerda conforme o que aparece na API do Bubble
CONDITION_MAP = {
    "new": "new",
    "novo": "new",
    "good": "good",
    "bom": "good",
    "boa": "good",
    "regular": "fair",
    "fair": "fair",
    "poor": "poor",
    "ruim": "poor",
    "péssimo": "poor",
    "under_maintenance": "under_maintenance",
    "manutenção": "under_maintenance",
    "manutencao": "under_maintenance",
    "em manutenção": "under_maintenance",
    "retired": "retired",
    "aposentado": "retired",
    "descartado": "retired",
}


class BubbleAPI:
    """Cliente para a API do Bubble com paginação automática"""

    def __init__(self, app_name: str, api_token: str):
        self.base_url = f"https://{app_name}.bubbleapps.io/api/1.1/obj"
        self.headers = {
            "Authorization": f"Bearer {api_token}",
            "Content-Type": "application/json"
        }

    def get_all_records(self, data_type: str) -> List[Dict]:
        """Busca todos os registros de uma tabela com paginação (100 por página)"""
        url = f"{self.base_url}/{data_type}"
        params = {"limit": 100, "cursor": 0}
        all_results = []

        print(f"  Buscando {data_type} no Bubble...")

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
                print(f"\n  ❌ Erro ao buscar página (cursor={params['cursor']}): {e}")
                break

        print(f"  → {len(all_results)} registros carregados.         ")
        return all_results


def map_condition(value: Optional[str]) -> Optional[str]:
    """Mapeia o valor do Bubble para o enum condition_status do Supabase"""
    if not value:
        return None
    return CONDITION_MAP.get(str(value).lower().strip())


def transform_patrimonio(record: Dict) -> Dict:
    """Mapeia campos do Bubble (Patrimonio) para a tabela patrimonio do Supabase"""
    return {
        "bubble_id":     record.get("_id"),
        "brand":         record.get("Brand"),
        "code":          record.get("code"),
        "condition":     map_condition(record.get("Condicao")),
        "date_received": record.get("Date Receiveid"),   # typo original do Bubble
        "descricao":     record.get("descricao"),
        "owner":         record.get("Owner"),
        "patrimonio":    record.get("Patrimonio"),
        "programa":      record.get("Programa"),
        "school_campus": record.get("School/Campus"),
        "admin":         record.get("Admin"),
        "creator":       record.get("Creator"),
        "slug":          record.get("Slug"),
        "created_date":  record.get("Created Date"),
        "modified_date": record.get("Modified Date"),
    }


def transform_inventory(record: Dict) -> Dict:
    """Mapeia campos do Bubble (Inventory) para a tabela inventory do Supabase"""
    return {
        "bubble_id":           record.get("_id"),
        "brand":               record.get("Brand"),
        "codigo":              record.get("Codigo"),
        "model":               record.get("Model"),
        "serial_number":       record.get("Serial Number"),
        "instrument":          record.get("Instrument"),
        "size":                record.get("Size"),
        "descricao":           record.get("descricao"),
        "inventory_filter":    record.get("Inventory_Filter"),
        "condition":           map_condition(record.get("Condition")),
        "date_received":       record.get("Date Received"),
        "owner":               record.get("Owner"),
        "issued_to":           record.get("Issued to"),
        "signed_term_date":    record.get("signed_term_date"),
        "parent_signature_url": record.get("parent_signature"),
        "photo_url":           record.get("Photo"),
        "qr_img_url":          record.get("QR-img"),
        "qr_file_url":         record.get("QR-file"),
        "programa":            record.get("programa"),
        "school_campus":       record.get("School/Campus"),
        "admin":               record.get("Admin"),
        "creator":             record.get("Creator"),
        "slug":                record.get("Slug"),
        "created_date":        record.get("Created Date"),
        "modified_date":       record.get("Modified Date"),
    }


def clean(record: Dict) -> Dict:
    """Remove campos None para não sobrescrever dados existentes"""
    return {k: v for k, v in record.items() if v is not None}


def migrate_table(
    bubble: BubbleAPI,
    supabase: Client,
    bubble_table: str,
    supabase_table: str,
    transform_fn,
    dry_run: bool
) -> Dict:
    """Migra todos os registros de uma tabela do Bubble para o Supabase"""

    print(f"\n{'─'*60}")
    print(f"  {supabase_table.upper()}")
    print(f"{'─'*60}")

    records = bubble.get_all_records(bubble_table)

    if not records:
        print("  ⚠️  Nenhum registro encontrado no Bubble.")
        return {"total": 0, "success": 0, "failed": 0, "skipped": 0}

    success = 0
    failed = 0
    skipped = 0
    failed_ids = []

    # Upsert em lotes de 50
    batch_size = 50
    batches = [records[i:i+batch_size] for i in range(0, len(records), batch_size)]

    print(f"  Enviando {len(records)} registros em {len(batches)} lote(s)...")

    for i, batch in enumerate(batches, 1):
        transformed = []
        for record in batch:
            row = clean(transform_fn(record))
            if not row.get("bubble_id"):
                skipped += 1
                continue
            transformed.append(row)

        if not transformed:
            continue

        if dry_run:
            print(f"  [DRY RUN] Lote {i}/{len(batches)}: {len(transformed)} registros (não gravado)")
            success += len(transformed)
            continue

        try:
            response = supabase.table(supabase_table).upsert(
                transformed,
                on_conflict="bubble_id"
            ).execute()

            batch_success = len(response.data) if response.data else 0
            batch_failed = len(transformed) - batch_success
            success += batch_success
            failed += batch_failed

            print(f"  Lote {i}/{len(batches)}: ✅ {batch_success} ok  ❌ {batch_failed} falha")

            if batch_failed > 0:
                failed_ids += [r.get("bubble_id") for r in transformed]

        except Exception as e:
            print(f"  ❌ Erro no lote {i}: {e}")
            failed += len(transformed)
            failed_ids += [r.get("bubble_id") for r in transformed]

    print(f"\n  Resultado: ✅ {success} migrados  ❌ {failed} falhas  ⏭️  {skipped} sem ID")

    if failed_ids:
        print(f"  IDs com falha: {failed_ids[:5]}{'...' if len(failed_ids) > 5 else ''}")

    return {"total": len(records), "success": success, "failed": failed, "skipped": skipped}


def main():
    parser = argparse.ArgumentParser(description="Migração única Bubble → Supabase (Patrimônio e Inventory)")
    parser.add_argument("--dry-run", action="store_true", help="Simula a migração sem gravar no banco")
    args = parser.parse_args()

    # Verificar variáveis de ambiente
    required = ["BUBBLE_APP_NAME", "BUBBLE_API_TOKEN", "SUPABASE_URL", "SUPABASE_SERVICE_KEY"]
    missing = [v for v in required if not os.getenv(v)]
    if missing:
        print("❌ Variáveis de ambiente faltando:")
        for v in missing:
            print(f"  - {v}")
        print("\nConfigure o arquivo .env")
        sys.exit(1)

    if args.dry_run:
        print("\n⚠️  MODO DRY RUN — nenhum dado será gravado no banco\n")

    print("=" * 60)
    print("  MIGRAÇÃO ÚNICA: BUBBLE → SUPABASE")
    print(f"  {datetime.now().strftime('%Y-%m-%d %H:%M:%S')}")
    print("=" * 60)

    bubble = BubbleAPI(
        app_name=os.getenv("BUBBLE_APP_NAME"),
        api_token=os.getenv("BUBBLE_API_TOKEN")
    )
    supabase: Client = create_client(
        os.getenv("SUPABASE_URL"),
        os.getenv("SUPABASE_SERVICE_KEY")
    )

    results = {}

    # Migrar Patrimônio
    results["patrimonio"] = migrate_table(
        bubble, supabase,
        bubble_table="Patrimonio",
        supabase_table="patrimonio",
        transform_fn=transform_patrimonio,
        dry_run=args.dry_run
    )

    # Migrar Inventory
    results["inventory"] = migrate_table(
        bubble, supabase,
        bubble_table="Inventory",
        supabase_table="inventory",
        transform_fn=transform_inventory,
        dry_run=args.dry_run
    )

    # Resumo final
    print(f"\n{'='*60}")
    print("  RESUMO FINAL")
    print(f"{'='*60}")
    total_migrated = sum(r["success"] for r in results.values())
    total_failed = sum(r["failed"] for r in results.values())
    for table, r in results.items():
        print(f"  {table}: {r['success']}/{r['total']} migrados")
    print(f"\n  Total: ✅ {total_migrated} migrados  ❌ {total_failed} falhas")

    if args.dry_run:
        print("\n  ⚠️  DRY RUN concluído — execute sem --dry-run para gravar")

    # Salvar log
    if not args.dry_run:
        import pathlib as _pl
        _logs_dir = _pl.Path(__file__).parent.parent / "logs"
        log_file = _logs_dir / f"migration_log_{datetime.now().strftime('%Y%m%d_%H%M%S')}.json"
        with open(log_file, "w", encoding="utf-8") as f:
            json.dump({
                "timestamp": datetime.now().isoformat(),
                "results": results
            }, f, indent=2, ensure_ascii=False)
        print(f"\n  📄 Log salvo em: {log_file}")

    print(f"{'='*60}\n")


if __name__ == "__main__":
    main()
