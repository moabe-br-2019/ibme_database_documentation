#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
Script para verificar sincronização entre Bubble.io e Supabase
Compara dados das tabelas: Students, Sociocultural Profile, class, programs
"""

import os
import sys
from datetime import datetime
from typing import Dict, List, Any, Tuple
import requests
from supabase import create_client, Client
from dotenv import load_dotenv
from collections import defaultdict

# Configurar encoding UTF-8 no Windows
if sys.platform == "win32":
    sys.stdout.reconfigure(encoding='utf-8')

# Carregar variáveis de ambiente
load_dotenv()


class BubbleAPI:
    """Cliente para API do Bubble.io"""

    def __init__(self, app_name: str, api_token: str):
        self.base_url = f"https://{app_name}.bubbleapps.io/api/1.1/obj"
        self.headers = {
            "Authorization": f"Bearer {api_token}",
            "Content-Type": "application/json"
        }

    def get_all_records(self, data_type: str, constraints: List[Dict] = None) -> List[Dict]:
        """Busca todos os registros de um tipo de dado do Bubble"""
        url = f"{self.base_url}/{data_type}"
        params = {
            "limit": 100,  # Bubble permite até 100 por página
            "cursor": 0
        }

        if constraints:
            params["constraints"] = constraints

        all_results = []

        while True:
            try:
                response = requests.get(url, headers=self.headers, params=params)
                response.raise_for_status()
                data = response.json()

                results = data.get("response", {}).get("results", [])
                all_results.extend(results)

                # Verificar se há mais páginas
                remaining = data.get("response", {}).get("remaining", 0)
                if remaining == 0:
                    break

                params["cursor"] += len(results)

            except requests.exceptions.RequestException as e:
                print(f"Erro ao buscar dados do Bubble ({data_type}): {e}")
                break

        return all_results


class SyncChecker:
    """Verificador de sincronização entre Bubble e Supabase"""

    def __init__(self):
        # Inicializar clientes
        self.bubble = BubbleAPI(
            app_name=os.getenv("BUBBLE_APP_NAME"),
            api_token=os.getenv("BUBBLE_API_TOKEN")
        )

        self.supabase: Client = create_client(
            os.getenv("SUPABASE_URL"),
            os.getenv("SUPABASE_SERVICE_KEY")
        )

        # Mapeamento de tabelas Bubble -> Supabase
        # Formato: "nome_bubble": ("nome_supabase", "nome_coluna_id_supabase")
        # Nota: Perfil Sociocultural usa URL encoding no Bubble
        self.table_mapping = {
            "student": ("Students", "unique id"),
            "Perfil%20Sociocultural": ("Sociocultural Profile", "unique id"),
            "classes": ("class", "unique_id"),
            "programs": ("programs", "unique_id")
        }

    def get_supabase_data(self, table_name: str) -> List[Dict]:
        """Busca dados de uma tabela do Supabase com paginação"""
        all_data = []
        page_size = 1000
        start = 0

        try:
            while True:
                end = start + page_size - 1
                response = self.supabase.table(table_name).select("*").range(start, end).execute()

                if not response.data:
                    break

                all_data.extend(response.data)

                # Se retornou menos que o page_size, chegamos ao fim
                if len(response.data) < page_size:
                    break

                start += page_size

            return all_data
        except Exception as e:
            print(f"Erro ao buscar dados do Supabase ({table_name}): {e}")
            return []

    def compare_counts(self) -> Dict[str, Tuple[int, int]]:
        """Compara quantidade de registros entre Bubble e Supabase"""
        print("\n" + "="*80)
        print("COMPARAÇÃO DE CONTAGEM DE REGISTROS")
        print("="*80 + "\n")

        results = {}

        for bubble_table, (supabase_table, _) in self.table_mapping.items():
            print(f"Verificando: {bubble_table}...")

            bubble_data = self.bubble.get_all_records(bubble_table)
            supabase_data = self.get_supabase_data(supabase_table)

            bubble_count = len(bubble_data)
            supabase_count = len(supabase_data)

            results[bubble_table] = (bubble_count, supabase_count)

            status = "✓ OK" if bubble_count == supabase_count else "✗ DIFERENÇA"
            diff = supabase_count - bubble_count

            print(f"  Bubble:    {bubble_count:>6} registros")
            print(f"  Supabase:  {supabase_count:>6} registros")
            print(f"  Status:    {status}")
            if diff != 0:
                print(f"  Diferença: {diff:+} registros")
            print()

        return results

    def compare_unique_ids(self, table_name: str) -> Dict[str, Any]:
        """Compara unique_ids entre Bubble e Supabase"""
        bubble_table = table_name
        table_info = self.table_mapping.get(table_name)

        if not table_info:
            return {"error": "Tabela não mapeada"}

        supabase_table, supabase_id_column = table_info

        print(f"\n{'='*80}")
        print(f"COMPARAÇÃO DETALHADA: {table_name.upper()}")
        print(f"{'='*80}\n")

        # Buscar dados
        bubble_data = self.bubble.get_all_records(bubble_table)
        supabase_data = self.get_supabase_data(supabase_table)

        # Extrair unique_ids
        # Bubble usa "_id" como campo padrão
        bubble_ids = set()
        for item in bubble_data:
            uid = item.get("_id")
            if uid:
                bubble_ids.add(str(uid))

        # Supabase usa o nome de coluna específico de cada tabela
        supabase_ids = set()
        for item in supabase_data:
            uid = item.get(supabase_id_column)
            if uid:
                supabase_ids.add(str(uid))

        # Calcular diferenças
        only_bubble = bubble_ids - supabase_ids
        only_supabase = supabase_ids - bubble_ids
        in_both = bubble_ids & supabase_ids

        # Relatório
        print(f"Total no Bubble:           {len(bubble_ids):>6}")
        print(f"Total no Supabase:         {len(supabase_ids):>6}")
        print(f"Presentes em ambos:        {len(in_both):>6}")
        print(f"Apenas no Bubble:          {len(only_bubble):>6}")
        print(f"Apenas no Supabase:        {len(only_supabase):>6}")

        if only_bubble:
            print(f"\n⚠ IDs apenas no Bubble (primeiros 10):")
            for uid in list(only_bubble)[:10]:
                print(f"  - {uid}")
            if len(only_bubble) > 10:
                print(f"  ... e mais {len(only_bubble) - 10}")

        if only_supabase:
            print(f"\n⚠ IDs apenas no Supabase (primeiros 10):")
            for uid in list(only_supabase)[:10]:
                print(f"  - {uid}")
            if len(only_supabase) > 10:
                print(f"  ... e mais {len(only_supabase) - 10}")

        return {
            "bubble_count": len(bubble_ids),
            "supabase_count": len(supabase_ids),
            "in_both": len(in_both),
            "only_bubble": list(only_bubble),
            "only_supabase": list(only_supabase)
        }

    def generate_report(self):
        """Gera relatório completo de sincronização"""
        print("\n" + "🔍 " + "="*76)
        print("  VERIFICAÇÃO DE SINCRONIZAÇÃO BUBBLE ↔ SUPABASE")
        print("  " + "="*76)
        print(f"  Data/Hora: {datetime.now().strftime('%Y-%m-%d %H:%M:%S')}")
        print("  " + "="*76)

        # Comparação de contagem
        count_results = self.compare_counts()

        # Análise detalhada de cada tabela
        detailed_results = {}
        for table in self.table_mapping.keys():
            detailed_results[table] = self.compare_unique_ids(table)

        # Resumo final
        print(f"\n{'='*80}")
        print("RESUMO FINAL")
        print(f"{'='*80}\n")

        total_issues = 0
        for table, (bubble_count, supabase_count) in count_results.items():
            if bubble_count != supabase_count:
                total_issues += 1

        if total_issues == 0:
            print("✓ Todas as tabelas estão sincronizadas!")
        else:
            print(f"⚠ {total_issues} tabela(s) com diferenças detectadas")
            print("\nRecomendações:")
            print("  1. Verifique os IDs listados acima")
            print("  2. Investigue registros recentes que podem estar em processamento")
            print("  3. Execute script de sincronização se necessário")

        print("\n" + "="*80 + "\n")

        return {
            "counts": count_results,
            "details": detailed_results,
            "timestamp": datetime.now().isoformat()
        }


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
        print("\nConfigure o arquivo .env com base no .env.example")
        sys.exit(1)

    # Executar verificação
    try:
        checker = SyncChecker()
        results = checker.generate_report()

        # Opcional: salvar resultados em JSON
        import json
        import pathlib as _pl
        _logs_dir = _pl.Path(__file__).parent.parent / "logs"
        output_file = _logs_dir / f"sync_report_{datetime.now().strftime('%Y%m%d_%H%M%S')}.json"
        with open(output_file, 'w', encoding='utf-8') as f:
            json.dump(results, f, indent=2, ensure_ascii=False)

        print(f"📄 Relatório salvo em: {output_file}")

    except Exception as e:
        print(f"❌ Erro ao executar verificação: {e}")
        import traceback
        traceback.print_exc()
        sys.exit(1)


if __name__ == "__main__":
    main()
