#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
Script de teste para ver a estrutura dos registros faltantes
"""

import os
import sys
import json
import requests
from dotenv import load_dotenv

# Configurar encoding UTF-8 no Windows
if sys.platform == "win32":
    sys.stdout.reconfigure(encoding='utf-8')

# Carregar variáveis de ambiente
load_dotenv()

def get_bubble_record_direct(table_name: str, record_id: str):
    """Busca um registro específico no Bubble pela URL direta"""
    app_name = os.getenv("BUBBLE_APP_NAME")
    api_token = os.getenv("BUBBLE_API_TOKEN")

    # Tentar buscar pela URL direta do objeto
    url = f"https://{app_name}.bubbleapps.io/api/1.1/obj/{table_name}/{record_id}"
    headers = {
        "Authorization": f"Bearer {api_token}",
        "Content-Type": "application/json"
    }

    try:
        response = requests.get(url, headers=headers, timeout=10)
        if response.status_code == 200:
            return response.json().get("response", {})
        else:
            print(f"Status code: {response.status_code}")
            print(f"Response: {response.text}")
            return None
    except Exception as e:
        print(f"Erro: {e}")
        return None

def get_bubble_record(table_name: str, record_id: str):
    """Busca um registro específico no Bubble usando list com filtro"""
    app_name = os.getenv("BUBBLE_APP_NAME")
    api_token = os.getenv("BUBBLE_API_TOKEN")

    url = f"https://{app_name}.bubbleapps.io/api/1.1/obj/{table_name}"
    headers = {
        "Authorization": f"Bearer {api_token}",
        "Content-Type": "application/json"
    }

    # Buscar todos e filtrar localmente (como último recurso)
    params = {"limit": 100}

    try:
        response = requests.get(url, headers=headers, params=params, timeout=10)
        data = response.json()
        results = data.get("response", {}).get("results", [])

        # Filtrar pelo _id
        for item in results:
            if item.get("_id") == record_id:
                return item

        return None
    except Exception as e:
        print(f"Erro: {e}")
        return None

# Testar Perfil Sociocultural
print("="*80)
print("PERFIL SOCIOCULTURAL - URL Direta")
print("="*80)
perfil = get_bubble_record_direct("Perfil%20Sociocultural", "1762540112914x575873640396226560")
if perfil:
    print(json.dumps(perfil, indent=2, ensure_ascii=False))
else:
    print("\nTentando buscar via lista...")
    perfil = get_bubble_record("Perfil%20Sociocultural", "1762540112914x575873640396226560")
    if perfil:
        print(json.dumps(perfil, indent=2, ensure_ascii=False))
    else:
        print("❌ Não encontrado")

# Testar uma Class
print("\n" + "="*80)
print("CLASS (exemplo) - URL Direta")
print("="*80)
classe = get_bubble_record_direct("classes", "1741272165747x542787742110318600")
if classe:
    print(json.dumps(classe, indent=2, ensure_ascii=False))
else:
    print("\nTentando buscar via lista...")
    classe = get_bubble_record("classes", "1741272165747x542787742110318600")
    if classe:
        print(json.dumps(classe, indent=2, ensure_ascii=False))
    else:
        print("❌ Não encontrado")
