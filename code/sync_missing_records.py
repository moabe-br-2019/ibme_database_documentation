#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
Script para sincronizar registros específicos que estão no Bubble mas não no Supabase
Sincroniza apenas os registros identificados como faltantes no relatório de sync
"""

import os
import sys
from typing import Dict, List, Any
import requests
from supabase import create_client, Client
from dotenv import load_dotenv

# Configurar encoding UTF-8 no Windows
if sys.platform == "win32":
    sys.stdout.reconfigure(encoding='utf-8')

# Carregar variáveis de ambiente
load_dotenv()


class MissingRecordsSync:
    """Sincronizador de registros faltantes entre Bubble e Supabase"""

    def __init__(self):
        # Inicializar cliente Bubble
        self.bubble_app = os.getenv("BUBBLE_APP_NAME")
        self.bubble_token = os.getenv("BUBBLE_API_TOKEN")
        self.bubble_base_url = f"https://{self.bubble_app}.bubbleapps.io/api/1.1/obj"
        self.bubble_headers = {
            "Authorization": f"Bearer {self.bubble_token}",
            "Content-Type": "application/json"
        }

        # Inicializar cliente Supabase
        self.supabase: Client = create_client(
            os.getenv("SUPABASE_URL"),
            os.getenv("SUPABASE_SERVICE_KEY")
        )

        # Registros faltantes identificados
        self.missing_records = {
            "Perfil%20Sociocultural": {
                "ids": ["1762540112914x575873640396226560"],
                "supabase_table": "Sociocultural Profile",
                "id_field": "unique id"
            },
            "classes": {
                "ids": [
                    "1741272165747x542787742110318600",
                    "1764246303011x177771201231321060",
                    "1763678117109x794128487277809700",
                    "1756921321069x612220525492043800"
                ],
                "supabase_table": "class",
                "id_field": "unique_id"
            }
        }

    def get_bubble_record_by_id(self, table_name: str, record_id: str) -> Dict:
        """Busca um registro específico no Bubble pelo _id usando URL direta"""
        url = f"{self.bubble_base_url}/{table_name}/{record_id}"

        try:
            response = requests.get(url, headers=self.bubble_headers, timeout=10)
            response.raise_for_status()
            data = response.json()
            record = data.get("response", {})

            if record and record.get("_id"):
                return record
            else:
                print(f"  ⚠️  Registro {record_id} não encontrado no Bubble")
                return None

        except Exception as e:
            print(f"  ❌ Erro ao buscar registro {record_id}: {e}")
            return None

    def transform_perfil_sociocultural(self, bubble_data: Dict) -> Dict:
        """Transforma dados do Perfil Sociocultural do Bubble para formato Supabase"""
        # Mapear todos os campos possíveis do Bubble para Supabase
        transformed = {
            "unique id": bubble_data.get("_id"),
            "student": bubble_data.get("student"),
            "qtde de moradores": bubble_data.get("qtde de moradores"),
            "comunidade?": bubble_data.get("comunidade?"),
            "comunidade_nome": bubble_data.get("comunidade_nome"),
            "cursando": bubble_data.get("cursando"),
            "escolaridade pai": bubble_data.get("escolaridade pai"),
            "escolaridade mãe": bubble_data.get("escolaridade mãe"),
            "faculdade": bubble_data.get("faculdade"),
            "pavimentação": bubble_data.get("pavimentação"),
            "recebe do IBME": bubble_data.get("recebe do IBME"),
            "Região": bubble_data.get("Região"),
            "renda familiar mensal": bubble_data.get("renda familiar mensal"),
            "rendimentos_beneficios": bubble_data.get("rendimentos_beneficios"),
            "Serviços_politicas": bubble_data.get("Serviços_politicas"),
            "Área de risco": bubble_data.get("Área de risco"),
            "Creation Date": bubble_data.get("Created Date"),
            "Modified Date": bubble_data.get("Modified Date"),
            "Creator": bubble_data.get("Created By"),
            "type": bubble_data.get("type"),
        }

        # Remover campos None para não sobrescrever dados existentes
        return {k: v for k, v in transformed.items() if v is not None}

    def transform_class(self, bubble_data: Dict) -> Dict:
        """Transforma dados de Class do Bubble para formato Supabase"""
        import json

        # Converter arrays para formato JSON se necessário
        day_of_week_list = bubble_data.get("Day of week_List")
        if isinstance(day_of_week_list, list):
            day_of_week_list = json.dumps(day_of_week_list)

        instrument_os = bubble_data.get("Instrument_OS")
        if isinstance(instrument_os, list):
            instrument_os = json.dumps(instrument_os)

        professores = bubble_data.get("professores")
        if isinstance(professores, list):
            professores = json.dumps(professores)

        transformed = {
            "unique_id": bubble_data.get("_id"),
            "admin": bubble_data.get("Admin"),
            "class_code": bubble_data.get("Class Code "),
            "class_location": bubble_data.get("class_location"),
            "day_of_week": bubble_data.get("Day of week"),
            "day_of_week_list": day_of_week_list,
            "descricao": bubble_data.get("descricao"),
            "duration": bubble_data.get("Duration"),
            "end_date": bubble_data.get("End date"),
            "ensemble": bubble_data.get("ensemble"),
            "instrument_inventory": bubble_data.get("Instrument_Inventory"),
            "instrument_os": instrument_os,
            "max_students": bubble_data.get("max_students"),
            "professores": professores,
            "program": bubble_data.get("program"),
            "retention_rate": str(bubble_data.get("Retention Rate")) if bubble_data.get("Retention Rate") is not None else None,
            "start_date": bubble_data.get("Start date"),
            "start_time": bubble_data.get("Start Time"),
        }

        # Remover campos None para não sobrescrever dados existentes
        return {k: v for k, v in transformed.items() if v is not None}

    def sync_record(self, bubble_table: str, record_id: str, supabase_table: str, id_field: str, transform_func):
        """Sincroniza um registro específico do Bubble para o Supabase"""
        print(f"\n📤 Sincronizando {record_id}...")

        # Buscar no Bubble
        bubble_data = self.get_bubble_record_by_id(bubble_table, record_id)

        if not bubble_data:
            return False

        # Transformar dados
        supabase_data = transform_func(bubble_data)

        try:
            # Fazer upsert no Supabase
            response = self.supabase.table(supabase_table).upsert(supabase_data).execute()

            if response.data:
                print(f"  ✅ Sincronizado com sucesso!")
                return True
            else:
                print(f"  ❌ Falha ao sincronizar")
                return False

        except Exception as e:
            print(f"  ❌ Erro ao fazer upsert: {e}")
            return False

    def sync_all_missing(self):
        """Sincroniza todos os registros faltantes"""
        print("\n" + "="*80)
        print("  SINCRONIZAÇÃO DE REGISTROS FALTANTES")
        print("="*80)
        print(f"\nTotal de registros a sincronizar: 5")
        print("  - Perfil Sociocultural: 1")
        print("  - Classes: 4")

        total_success = 0
        total_failed = 0

        # Sincronizar Perfil Sociocultural
        print("\n" + "-"*80)
        print("PERFIL SOCIOCULTURAL")
        print("-"*80)

        config = self.missing_records["Perfil%20Sociocultural"]
        for record_id in config["ids"]:
            success = self.sync_record(
                "Perfil%20Sociocultural",
                record_id,
                config["supabase_table"],
                config["id_field"],
                self.transform_perfil_sociocultural
            )
            if success:
                total_success += 1
            else:
                total_failed += 1

        # Sincronizar Classes
        print("\n" + "-"*80)
        print("CLASSES")
        print("-"*80)

        config = self.missing_records["classes"]
        for record_id in config["ids"]:
            success = self.sync_record(
                "classes",
                record_id,
                config["supabase_table"],
                config["id_field"],
                self.transform_class
            )
            if success:
                total_success += 1
            else:
                total_failed += 1

        # Resumo final
        print("\n" + "="*80)
        print("RESUMO")
        print("="*80)
        print(f"✅ Sincronizados com sucesso: {total_success}")
        print(f"❌ Falharam:                  {total_failed}")
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
        print("\nConfigure o arquivo .env")
        sys.exit(1)

    # Executar sincronização
    try:
        syncer = MissingRecordsSync()
        syncer.sync_all_missing()

    except Exception as e:
        print(f"❌ Erro ao executar sincronização: {e}")
        import traceback
        traceback.print_exc()
        sys.exit(1)


if __name__ == "__main__":
    main()
