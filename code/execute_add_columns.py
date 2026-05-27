#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
Script para executar SQL de adição de colunas diretamente no Supabase
"""

import os
import sys
from dotenv import load_dotenv
from supabase import create_client, Client

# Configurar encoding UTF-8 no Windows
if sys.platform == "win32":
    sys.stdout.reconfigure(encoding='utf-8')

# Carregar variáveis de ambiente
load_dotenv()


def execute_sql():
    """Executa SQL para adicionar colunas"""

    # Conectar ao Supabase
    supabase: Client = create_client(
        os.getenv("SUPABASE_URL"),
        os.getenv("SUPABASE_SERVICE_KEY")
    )

    sql_statements = [
        # class - Contadores de alunos
        '''ALTER TABLE "public"."class" ADD COLUMN IF NOT EXISTS "current_students_count" integer DEFAULT 0''',
        '''ALTER TABLE "public"."class" ADD COLUMN IF NOT EXISTS "original_students_count" integer DEFAULT 0''',

        # class - ID alternativo
        '''ALTER TABLE "public"."class" ADD COLUMN IF NOT EXISTS "ID" text''',

        # class - Arrays
        '''ALTER TABLE "public"."class" ADD COLUMN IF NOT EXISTS "Schedule" jsonb''',
        '''ALTER TABLE "public"."class" ADD COLUMN IF NOT EXISTS "Students" jsonb''',

        # programs - Hierarquia
        '''ALTER TABLE "public"."programs" ADD COLUMN IF NOT EXISTS "os_prog_raiz" text''',

        # programs - Referências
        '''ALTER TABLE "public"."programs" ADD COLUMN IF NOT EXISTS "class" text''',
        '''ALTER TABLE "public"."programs" ADD COLUMN IF NOT EXISTS "teacher" text''',

        # programs - Lista de instrumentos
        '''ALTER TABLE "public"."programs" ADD COLUMN IF NOT EXISTS "lista de instrumentos" text''',

        # Sociocultural Profile - Campos específicos
        '''ALTER TABLE "public"."Sociocultural Profile" ADD COLUMN IF NOT EXISTS "Serviços/políticas" text''',
        '''ALTER TABLE "public"."Sociocultural Profile" ADD COLUMN IF NOT EXISTS "rendimentos/benefícios" text''',
    ]

    print("\n" + "="*80)
    print("  ADICIONANDO COLUNAS NO SUPABASE")
    print("="*80 + "\n")

    success_count = 0
    error_count = 0

    for i, sql in enumerate(sql_statements, 1):
        try:
            # Extrair nome da tabela e coluna para exibição
            parts = sql.split('"')
            table = parts[3] if len(parts) > 3 else "?"
            column = parts[7] if len(parts) > 7 else "?"

            print(f"[{i}/{len(sql_statements)}] Adicionando {column} em {table}...", end=" ")

            # Executar SQL via RPC (Supabase Python client não tem método direto para SQL)
            # Vamos usar o postgrest diretamente
            response = supabase.postgrest.session.post(
                f"{os.getenv('SUPABASE_URL')}/rest/v1/rpc/exec_sql",
                json={"sql": sql},
                headers={
                    "apikey": os.getenv("SUPABASE_SERVICE_KEY"),
                    "Authorization": f"Bearer {os.getenv('SUPABASE_SERVICE_KEY')}"
                }
            )

            if response.status_code in [200, 201, 204]:
                print("✅")
                success_count += 1
            else:
                print(f"❌ ({response.status_code})")
                error_count += 1

        except Exception as e:
            print(f"❌ Erro: {e}")
            error_count += 1

    print("\n" + "="*80)
    print(f"Resultado: {success_count} sucesso, {error_count} erros")
    print("="*80 + "\n")

    if error_count > 0:
        print("⚠️  Alguns comandos falharam.")
        print("Você pode executar o SQL manualmente no Supabase Dashboard:")
        print("   1. Acesse https://supabase.com/dashboard")
        print("   2. Vá em SQL Editor")
        print("   3. Execute o arquivo: add_new_fields_only.sql")
        print()


if __name__ == "__main__":
    print("\n⚠️  NOTA: O cliente Python do Supabase não suporta execução direta de SQL.")
    print("Recomendação: Execute o script SQL manualmente no Supabase Dashboard.\n")
    print("Arquivo: add_new_fields_only.sql\n")

    response = input("Deseja tentar via API mesmo assim? (s/n): ")
    if response.lower() == 's':
        execute_sql()
    else:
        print("\nAbra o Supabase Dashboard e execute add_new_fields_only.sql")
        print("https://supabase.com/dashboard")
