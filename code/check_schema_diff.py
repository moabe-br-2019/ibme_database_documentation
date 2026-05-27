#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
Script para comparar colunas/campos entre Bubble e Supabase
Identifica campos novos no Bubble que não existem no Supabase
"""

import os
import sys
import json
from typing import Dict, List, Set
import requests
from supabase import create_client, Client
from dotenv import load_dotenv

# Configurar encoding UTF-8 no Windows
if sys.platform == "win32":
    sys.stdout.reconfigure(encoding='utf-8')

# Carregar variáveis de ambiente
load_dotenv()


class SchemaComparator:
    """Comparador de schemas entre Bubble e Supabase"""

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

        # Mapeamento de tabelas
        self.table_mapping = {
            "student": "Students",
            "Perfil%20Sociocultural": "Sociocultural Profile",
            "classes": "class",
            "programs": "programs"
        }

    def get_bubble_fields(self, table_name: str, sample_size: int = 10) -> Set[str]:
        """Obtém todos os campos de uma tabela do Bubble analisando múltiplos registros"""
        url = f"{self.bubble_base_url}/{table_name}"
        params = {"limit": sample_size}

        all_fields = set()

        try:
            response = requests.get(url, headers=self.bubble_headers, params=params, timeout=10)
            response.raise_for_status()
            data = response.json()
            results = data.get("response", {}).get("results", [])

            # Coletar todos os campos de todos os registros
            for record in results:
                all_fields.update(record.keys())

            return all_fields

        except Exception as e:
            print(f"❌ Erro ao buscar campos do Bubble ({table_name}): {e}")
            return set()

    def get_supabase_fields(self, table_name: str) -> Set[str]:
        """Obtém todos os campos de uma tabela do Supabase"""
        try:
            # Buscar apenas 1 registro para ver os campos
            response = self.supabase.table(table_name).select("*").limit(1).execute()

            if response.data and len(response.data) > 0:
                return set(response.data[0].keys())
            else:
                # Se não há dados, tentar obter do schema via uma query vazia
                response = self.supabase.table(table_name).select("*").limit(0).execute()
                # Infelizmente isso também retorna vazio, vamos precisar usar outra abordagem
                print(f"  ⚠️  Tabela {table_name} vazia, não foi possível obter campos")
                return set()

        except Exception as e:
            print(f"❌ Erro ao buscar campos do Supabase ({table_name}): {e}")
            return set()

    def compare_schemas(self):
        """Compara schemas de todas as tabelas"""
        print("\n" + "="*80)
        print("  COMPARAÇÃO DE SCHEMAS - BUBBLE ↔ SUPABASE")
        print("="*80)
        print(f"\nAnalisando {len(self.table_mapping)} tabelas...\n")

        results = {}

        for bubble_table, supabase_table in self.table_mapping.items():
            print(f"\n{'─'*80}")
            print(f"📊 {bubble_table.replace('%20', ' ')} → {supabase_table}")
            print(f"{'─'*80}")

            # Buscar campos
            bubble_fields = self.get_bubble_fields(bubble_table)
            supabase_fields = self.get_supabase_fields(supabase_table)

            # Calcular diferenças
            only_bubble = bubble_fields - supabase_fields
            only_supabase = supabase_fields - bubble_fields
            in_both = bubble_fields & supabase_fields

            # Exibir resultados
            print(f"\n📋 Total de campos:")
            print(f"   Bubble:    {len(bubble_fields):>3} campos")
            print(f"   Supabase:  {len(supabase_fields):>3} campos")
            print(f"   Em ambos:  {len(in_both):>3} campos")

            if only_bubble:
                print(f"\n🆕 Campos NOVOS no Bubble (não existem no Supabase): {len(only_bubble)}")
                for field in sorted(only_bubble):
                    print(f"   ➕ {field}")

            if only_supabase:
                print(f"\n⚠️  Campos apenas no Supabase (não existem no Bubble): {len(only_supabase)}")
                for field in sorted(only_supabase):
                    print(f"   ➖ {field}")

            if not only_bubble and not only_supabase:
                print(f"\n✅ Schemas idênticos!")

            # Armazenar resultados
            results[bubble_table] = {
                "bubble_fields": sorted(list(bubble_fields)),
                "supabase_fields": sorted(list(supabase_fields)),
                "only_bubble": sorted(list(only_bubble)),
                "only_supabase": sorted(list(only_supabase)),
                "in_both": sorted(list(in_both))
            }

        # Resumo geral
        print(f"\n{'='*80}")
        print("RESUMO GERAL")
        print(f"{'='*80}\n")

        total_new_fields = sum(len(r["only_bubble"]) for r in results.values())
        total_missing_fields = sum(len(r["only_supabase"]) for r in results.values())

        print(f"🆕 Total de campos novos no Bubble: {total_new_fields}")
        print(f"⚠️  Total de campos apenas no Supabase: {total_missing_fields}")

        if total_new_fields > 0:
            print(f"\n💡 Recomendação:")
            print(f"   Execute 'supabase db dump --linked -s public > schema.sql'")
            print(f"   para atualizar o schema local com as mudanças do Supabase.")
            print(f"   Ou adicione as colunas manualmente no Supabase Dashboard.")

        print(f"\n{'='*80}\n")

        return results


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

    # Executar comparação
    try:
        comparator = SchemaComparator()
        results = comparator.compare_schemas()

        # Salvar resultados em JSON
        import pathlib as _pl
        _root = _pl.Path(__file__).parent.parent
        output_file = _root / "logs" / "schema_diff_report.json"
        with open(output_file, 'w', encoding='utf-8') as f:
            json.dump(results, f, indent=2, ensure_ascii=False)

        print(f"📄 Relatório detalhado salvo em: {output_file}\n")

    except Exception as e:
        print(f"❌ Erro ao executar comparação: {e}")
        import traceback
        traceback.print_exc()
        sys.exit(1)


if __name__ == "__main__":
    main()
