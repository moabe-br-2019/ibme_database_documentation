#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
Script para sincronizar os NOVOS campos do Bubble para o Supabase
Sincroniza apenas: current_students_count, original_students_count, ID, Schedule, Students (class)
                   os_prog_raiz, class, teacher, lista de instrumentos (programs)
                   Serviços/políticas, rendimentos/benefícios (Sociocultural Profile)
"""

import os
import sys
import json
from typing import Dict, List
import requests
from supabase import create_client, Client
from dotenv import load_dotenv

# Configurar encoding UTF-8 no Windows
if sys.platform == "win32":
    sys.stdout.reconfigure(encoding='utf-8')

# Carregar variáveis de ambiente
load_dotenv()


class NewFieldsSync:
    """Sincronizador de campos novos"""

    def __init__(self):
        # Bubble client
        self.bubble_app = os.getenv("BUBBLE_APP_NAME")
        self.bubble_token = os.getenv("BUBBLE_API_TOKEN")
        self.bubble_base_url = f"https://{self.bubble_app}.bubbleapps.io/api/1.1/obj"
        self.bubble_headers = {
            "Authorization": f"Bearer {self.bubble_token}",
            "Content-Type": "application/json"
        }

        # Supabase client
        self.supabase: Client = create_client(
            os.getenv("SUPABASE_URL"),
            os.getenv("SUPABASE_SERVICE_KEY")
        )

    def get_all_bubble_records(self, table_name: str) -> List[Dict]:
        """Busca todos os registros de uma tabela do Bubble"""
        url = f"{self.bubble_base_url}/{table_name}"
        all_records = []
        cursor = 0

        while True:
            try:
                response = requests.get(
                    url,
                    headers=self.bubble_headers,
                    params={"limit": 100, "cursor": cursor},
                    timeout=10
                )
                response.raise_for_status()
                data = response.json()
                results = data.get("response", {}).get("results", [])

                if not results:
                    break

                all_records.extend(results)

                remaining = data.get("response", {}).get("remaining", 0)
                if remaining == 0:
                    break

                cursor += len(results)

            except Exception as e:
                print(f"  ❌ Erro ao buscar registros: {e}")
                break

        return all_records

    def sync_class_fields(self):
        """Sincroniza campos novos da tabela class"""
        print("\n" + "─"*80)
        print("📊 SINCRONIZANDO: class")
        print("─"*80)

        # Buscar do Bubble
        print("  Buscando dados do Bubble...")
        bubble_records = self.get_all_bubble_records("classes")
        print(f"  ✓ {len(bubble_records)} registros encontrados")

        success = 0
        errors = 0

        for record in bubble_records:
            try:
                unique_id = record.get("_id")
                if not unique_id:
                    continue

                # Preparar dados dos novos campos
                update_data = {}

                if "current_students_count" in record:
                    update_data["current_students_count"] = record["current_students_count"]

                if "original_students_count" in record:
                    update_data["original_students_count"] = record["original_students_count"]

                if "ID" in record:
                    update_data["ID"] = record["ID"]

                if "Schedule" in record:
                    update_data["Schedule"] = json.dumps(record["Schedule"]) if isinstance(record["Schedule"], list) else record["Schedule"]

                if "Students" in record:
                    update_data["Students"] = json.dumps(record["Students"]) if isinstance(record["Students"], list) else record["Students"]

                # Se não há nada para atualizar, pular
                if not update_data:
                    continue

                # Atualizar no Supabase
                response = self.supabase.table("class").update(update_data).eq("unique_id", unique_id).execute()

                if response.data:
                    success += 1
                else:
                    errors += 1

            except Exception as e:
                errors += 1
                print(f"  ⚠️  Erro no registro {unique_id}: {e}")

        print(f"\n  ✅ Sincronizados: {success}")
        print(f"  ❌ Erros: {errors}")

    def sync_programs_fields(self):
        """Sincroniza campos novos da tabela programs"""
        print("\n" + "─"*80)
        print("📊 SINCRONIZANDO: programs")
        print("─"*80)

        # Buscar do Bubble
        print("  Buscando dados do Bubble...")
        bubble_records = self.get_all_bubble_records("programs")
        print(f"  ✓ {len(bubble_records)} registros encontrados")

        success = 0
        errors = 0

        for record in bubble_records:
            try:
                unique_id = record.get("_id")
                if not unique_id:
                    continue

                # Preparar dados dos novos campos
                update_data = {}

                if "os_prog_raiz" in record:
                    update_data["os_prog_raiz"] = record["os_prog_raiz"]

                if "class" in record:
                    update_data["class"] = record["class"]

                if "teacher" in record:
                    update_data["teacher"] = record["teacher"]

                if "lista de instrumentos" in record:
                    update_data["lista de instrumentos"] = record["lista de instrumentos"]

                # Se não há nada para atualizar, pular
                if not update_data:
                    continue

                # Atualizar no Supabase
                response = self.supabase.table("programs").update(update_data).eq("unique_id", unique_id).execute()

                if response.data:
                    success += 1
                else:
                    errors += 1

            except Exception as e:
                errors += 1
                print(f"  ⚠️  Erro no registro {unique_id}: {e}")

        print(f"\n  ✅ Sincronizados: {success}")
        print(f"  ❌ Erros: {errors}")

    def sync_perfil_fields(self):
        """Sincroniza campos novos da tabela Sociocultural Profile"""
        print("\n" + "─"*80)
        print("📊 SINCRONIZANDO: Sociocultural Profile")
        print("─"*80)

        # Buscar do Bubble
        print("  Buscando dados do Bubble...")
        bubble_records = self.get_all_bubble_records("Perfil%20Sociocultural")
        print(f"  ✓ {len(bubble_records)} registros encontrados")

        success = 0
        errors = 0

        for record in bubble_records:
            try:
                unique_id = record.get("_id")
                if not unique_id:
                    continue

                # Preparar dados dos novos campos
                update_data = {}

                if "Serviços/políticas" in record:
                    update_data["Serviços/políticas"] = record["Serviços/políticas"]

                if "rendimentos/benefícios" in record:
                    update_data["rendimentos/benefícios"] = record["rendimentos/benefícios"]

                # Se não há nada para atualizar, pular
                if not update_data:
                    continue

                # Atualizar no Supabase
                response = self.supabase.table("Sociocultural Profile").update(update_data).eq("unique id", unique_id).execute()

                if response.data:
                    success += 1
                else:
                    errors += 1

            except Exception as e:
                errors += 1
                print(f"  ⚠️  Erro no registro {unique_id}: {e}")

        print(f"\n  ✅ Sincronizados: {success}")
        print(f"  ❌ Erros: {errors}")

    def run(self):
        """Executa sincronização completa"""
        print("\n" + "="*80)
        print("  SINCRONIZAÇÃO DE CAMPOS NOVOS - BUBBLE → SUPABASE")
        print("="*80)

        self.sync_class_fields()
        self.sync_programs_fields()
        self.sync_perfil_fields()

        print("\n" + "="*80)
        print("✅ Sincronização concluída!")
        print("="*80 + "\n")


def main():
    """Função principal"""
    # Verificar variáveis de ambiente
    required_vars = [
        "BUBBLE_APP_NAME",
        "BUBBLE_API_TOKEN",
        "SUPABASE_URL",
        "SUPABASE_SERVICE_KEY"
    ]

    missing_vars = [var for var in required_vars if not os.getenv(var)]

    if missing_vars:
        print("❌ Erro: Variáveis de ambiente faltando:")
        for var in missing_vars:
            print(f"  - {var}")
        sys.exit(1)

    # Executar sincronização
    try:
        syncer = NewFieldsSync()
        syncer.run()

    except Exception as e:
        print(f"❌ Erro: {e}")
        import traceback
        traceback.print_exc()
        sys.exit(1)


if __name__ == "__main__":
    main()
