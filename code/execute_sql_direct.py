#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
Script para executar SQL diretamente no Supabase via psycopg2
"""

import os
import sys
import psycopg2
from dotenv import load_dotenv
from urllib.parse import urlparse

# Configurar encoding UTF-8 no Windows
if sys.platform == "win32":
    sys.stdout.reconfigure(encoding='utf-8')

# Carregar variáveis de ambiente
load_dotenv()


def execute_sql_file(filepath: str):
    """Executa um arquivo SQL no Supabase"""

    # Ler o arquivo SQL
    with open(filepath, 'r', encoding='utf-8') as f:
        sql = f.read()

    # Construir connection string
    supabase_url = os.getenv("SUPABASE_URL")

    # Extrair o host do URL
    parsed = urlparse(supabase_url)
    project_ref = parsed.hostname.split('.')[0] if parsed.hostname else None

    if not project_ref:
        print("❌ Erro: Não foi possível extrair o project ref do SUPABASE_URL")
        return False

    # Connection string para Supabase
    # Formato: postgresql://postgres:[PASSWORD]@db.[PROJECT_REF].supabase.co:5432/postgres
    conn_string = f"postgresql://postgres.{project_ref}:{os.getenv('SUPABASE_SERVICE_KEY')}@aws-0-us-east-1.pooler.supabase.com:6543/postgres"

    print("\n" + "="*80)
    print("  EXECUTANDO SQL NO SUPABASE")
    print("="*80)
    print(f"\nArquivo: {filepath}")
    print(f"Conectando ao projeto: {project_ref}")
    print()

    try:
        # Conectar ao banco
        conn = psycopg2.connect(conn_string)
        conn.autocommit = True
        cursor = conn.cursor()

        print("✅ Conexão estabelecida")
        print("\nExecutando comandos SQL...")
        print("-"*80)

        # Dividir em statements individuais
        statements = [s.strip() for s in sql.split(';') if s.strip() and not s.strip().startswith('--')]

        success_count = 0
        for i, statement in enumerate(statements, 1):
            if 'COMMENT ON' in statement or 'DO $$' in statement:
                continue  # Pular comments e blocos DO por enquanto

            try:
                cursor.execute(statement)

                # Extrair nome da coluna para exibir
                if 'ADD COLUMN' in statement:
                    parts = statement.split('"')
                    table = parts[3] if len(parts) > 3 else "?"
                    column = parts[7] if len(parts) > 7 else "?"
                    print(f"[{i}] ✅ Coluna '{column}' adicionada em '{table}'")
                    success_count += 1

            except Exception as e:
                if "already exists" in str(e):
                    print(f"[{i}] ⚠️  Coluna já existe (ignorado)")
                else:
                    print(f"[{i}] ❌ Erro: {e}")

        print("-"*80)
        print(f"\n✅ Comandos executados com sucesso: {success_count}")
        print("\n" + "="*80)
        print("✅ CONCLUÍDO!")
        print("="*80 + "\n")

        cursor.close()
        conn.close()

        return True

    except Exception as e:
        print(f"\n❌ Erro ao executar SQL: {e}")
        print("\nDetalhes do erro:")
        import traceback
        traceback.print_exc()
        return False


if __name__ == "__main__":
    import pathlib as _pl
    _sql_path = str(_pl.Path(__file__).parent.parent / "sql" / "add_new_fields_only.sql")
    success = execute_sql_file(_sql_path)

    if success:
        print("🎉 Colunas adicionadas com sucesso!")
        print("\nPróximo passo: Execute o script de sincronização de dados:")
        print("   python sync_new_fields.py")
    else:
        print("\n⚠️  Falha ao executar SQL.")
        print("Alternativa: Execute manualmente no Supabase Dashboard")
        print("   https://supabase.com/dashboard")

    sys.exit(0 if success else 1)
