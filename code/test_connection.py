#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
Script de teste de conexão com Bubble e Supabase
Use este script para verificar se suas credenciais estão corretas
"""

import os
import sys
from dotenv import load_dotenv
import requests
from supabase import create_client

# Configurar encoding UTF-8 no Windows
if sys.platform == "win32":
    sys.stdout.reconfigure(encoding='utf-8')

# Carregar variáveis de ambiente
load_dotenv()


def test_bubble_connection():
    """Testa conexão com a API do Bubble"""
    print("\n🔵 Testando conexão com Bubble.io...")

    app_name = os.getenv("BUBBLE_APP_NAME")
    api_token = os.getenv("BUBBLE_API_TOKEN")

    if not app_name or not api_token:
        print("❌ ERRO: BUBBLE_APP_NAME ou BUBBLE_API_TOKEN não configurados")
        return False

    # Tentar diferentes variações do nome da tabela
    table_variations = ["student", "students", "Student", "Students"]

    headers = {
        "Authorization": f"Bearer {api_token}",
        "Content-Type": "application/json"
    }
    params = {"limit": 1}

    for table_name in table_variations:
        try:
            url = f"https://{app_name}.bubbleapps.io/api/1.1/obj/{table_name}"
            response = requests.get(url, headers=headers, params=params, timeout=10)

            if response.status_code == 200:
                data = response.json()
                count = len(data.get("response", {}).get("results", []))
                total = data.get("response", {}).get("count", 0)
                print(f"✅ Conexão com Bubble OK!")
                print(f"   App: {app_name}")
                print(f"   Tabela encontrada: '{table_name}'")
                print(f"   Total de registros: {total}")
                return True
            elif response.status_code == 401:
                print(f"❌ ERRO: Token inválido ou expirado")
                print(f"   Verifique o BUBBLE_API_TOKEN no arquivo .env")
                return False

        except requests.exceptions.Timeout:
            print("❌ ERRO: Timeout na conexão com Bubble")
            return False
        except requests.exceptions.RequestException as e:
            continue

    # Se nenhuma variação funcionou
    print(f"❌ ERRO: Nenhuma tabela de students encontrada")
    print(f"   Tentamos: {', '.join(table_variations)}")
    print(f"   Verifique:")
    print(f"   1. Se o BUBBLE_APP_NAME está correto: '{app_name}'")
    print(f"   2. Se a API está habilitada para a tabela no Bubble")
    print(f"   3. Se a tabela tem outro nome no Bubble")
    return False


def test_supabase_connection():
    """Testa conexão com Supabase"""
    print("\n🟢 Testando conexão com Supabase...")

    url = os.getenv("SUPABASE_URL")
    key = os.getenv("SUPABASE_SERVICE_KEY")

    if not url or not key:
        print("❌ ERRO: SUPABASE_URL ou SUPABASE_SERVICE_KEY não configurados")
        return False

    try:
        supabase = create_client(url, key)

        # Tenta buscar da tabela Students como teste
        # Nota: A coluna é "unique id" (com espaço)
        response = supabase.table("Students").select('"unique id"', count="exact").limit(1).execute()

        print(f"✅ Conexão com Supabase OK!")
        print(f"   URL: {url}")
        print(f"   Total de Students: {response.count}")
        return True

    except Exception as e:
        print(f"❌ ERRO ao conectar com Supabase: {e}")
        print(f"   Verifique as credenciais no arquivo .env")
        return False


def main():
    """Função principal"""
    print("\n" + "="*60)
    print("  TESTE DE CONEXÃO - BUBBLE & SUPABASE")
    print("="*60)

    # Verificar se arquivo .env existe
    if not os.path.exists(".env"):
        print("\n❌ ERRO: Arquivo .env não encontrado!")
        print("   1. Copie .env.example para .env")
        print("   2. Configure suas credenciais")
        print("\n   Comando: cp .env.example .env")
        return

    # Testar conexões
    bubble_ok = test_bubble_connection()
    supabase_ok = test_supabase_connection()

    # Resumo
    print("\n" + "="*60)
    print("  RESUMO")
    print("="*60)
    print(f"  Bubble:    {'✅ OK' if bubble_ok else '❌ FALHOU'}")
    print(f"  Supabase:  {'✅ OK' if supabase_ok else '❌ FALHOU'}")
    print("="*60)

    if bubble_ok and supabase_ok:
        print("\n🎉 Tudo pronto! Você pode executar o sync_checker.py")
    else:
        print("\n⚠️  Corrija as credenciais antes de executar o sync_checker.py")

    print()


if __name__ == "__main__":
    main()
