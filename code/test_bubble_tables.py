#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
Script para testar e descobrir as tabelas corretas do Bubble
"""

import os
import sys
import requests
from dotenv import load_dotenv

# Configurar encoding UTF-8 no Windows
if sys.platform == "win32":
    sys.stdout.reconfigure(encoding='utf-8')

# Carregar variáveis de ambiente
load_dotenv()

def test_bubble_table(app_name, api_token, table_name):
    """Testa uma tabela do Bubble e retorna informações básicas"""
    url = f"https://{app_name}.bubbleapps.io/api/1.1/obj/{table_name}"
    headers = {
        "Authorization": f"Bearer {api_token}",
        "Content-Type": "application/json"
    }
    params = {"limit": 5}  # Apenas 5 registros para teste

    try:
        response = requests.get(url, headers=headers, params=params, timeout=10)

        if response.status_code == 200:
            data = response.json()
            results = data.get("response", {}).get("results", [])
            count = data.get("response", {}).get("count", 0)

            print(f"\n✅ Tabela '{table_name}' encontrada!")
            print(f"   Total de registros: {count}")

            if results:
                print(f"   Campos do primeiro registro:")
                first_record = results[0]
                for key in sorted(first_record.keys())[:15]:  # Mostrar até 15 campos
                    value = first_record[key]
                    if isinstance(value, str) and len(value) > 50:
                        value = value[:50] + "..."
                    print(f"     - {key}: {type(value).__name__}")

                if len(first_record.keys()) > 15:
                    print(f"     ... e mais {len(first_record.keys()) - 15} campos")

            return True
        else:
            print(f"❌ Tabela '{table_name}' não encontrada (Status: {response.status_code})")
            return False

    except Exception as e:
        print(f"❌ Erro ao testar '{table_name}': {e}")
        return False


def main():
    """Função principal"""
    app_name = os.getenv("BUBBLE_APP_NAME")
    api_token = os.getenv("BUBBLE_API_TOKEN")

    if not app_name or not api_token:
        print("❌ Erro: Configure BUBBLE_APP_NAME e BUBBLE_API_TOKEN no .env")
        sys.exit(1)

    print("="*80)
    print("DESCOBRINDO TABELAS DO BUBBLE")
    print("="*80)
    print(f"\nApp: {app_name}")

    # Testar diferentes variações de nomes de tabelas
    tables_to_test = {
        "Alunos": [
            "student",
            "students",
            "Student",
            "Students"
        ],
        "Perfil Sociocultural": [
            "Perfil%20Sociocultural",
            "Perfil Sociocultural",
            "socioculturalprofile",
            "sociocultural_profile",
            "SocioculturalProfile",
            "perfil_sociocultural"
        ],
        "Turmas": [
            "class",
            "classes",
            "Class",
            "Classes",
            "turma",
            "turmas"
        ],
        "Programas": [
            "program",
            "programs",
            "Program",
            "Programs",
            "programa",
            "programas"
        ]
    }

    print("\n" + "="*80)
    print("RESULTADOS")
    print("="*80)

    found_tables = {}

    for category, variations in tables_to_test.items():
        print(f"\n📋 Categoria: {category}")
        for table in variations:
            if test_bubble_table(app_name, api_token, table):
                if category not in found_tables:
                    found_tables[category] = table
                break  # Encontrou, não precisa testar outras variações

    # Resumo
    print("\n" + "="*80)
    print("RESUMO - TABELAS ENCONTRADAS")
    print("="*80)

    if found_tables:
        print("\nMapeamento correto para usar no sync_checker.py:\n")
        print("self.table_mapping = {")
        for category, table in found_tables.items():
            supabase_name = {
                "Alunos": "Students",
                "Perfil Sociocultural": "Sociocultural Profile",
                "Turmas": "class",
                "Programas": "programs"
            }.get(category, table)

            id_column = "unique id" if "Sociocultural" in category or "Alunos" in category else "unique_id"
            print(f'    "{table}": ("{supabase_name}", "{id_column}"),')
        print("}")
    else:
        print("\n⚠️  Nenhuma tabela foi encontrada. Verifique:")
        print("  1. Se o token da API está correto")
        print("  2. Se a API está habilitada para essas tabelas no Bubble")
        print("  3. Se os nomes das tabelas estão corretos")

    print("\n" + "="*80)


if __name__ == "__main__":
    main()
