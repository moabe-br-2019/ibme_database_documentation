#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
Analisa o relatório de diferenças de schema para identificar campos realmente novos
vs campos que são apenas variações de nomenclatura
"""

import json
import re
import sys
import pathlib

# Configurar encoding UTF-8 no Windows
if sys.platform == "win32":
    sys.stdout.reconfigure(encoding='utf-8')

_ROOT = pathlib.Path(__file__).parent.parent  # raiz do projeto


def normalize_field_name(name: str) -> str:
    """Normaliza um nome de campo para comparação"""
    # Remover espaços extras no final
    name = name.strip()
    # Converter para lowercase
    name = name.lower()
    # Substituir espaços por underscores
    name = name.replace(" ", "_")
    # Remover caracteres especiais
    name = re.sub(r'[^\w_]', '', name)
    # Remover underscores múltiplos
    name = re.sub(r'_+', '_', name)
    # Remover underscores no início e fim
    name = name.strip('_')

    return name


def analyze_schema_diff():
    """Analisa o relatório de diferenças de schema"""

    with open(_ROOT / 'logs' / 'schema_diff_report.json', 'r', encoding='utf-8') as f:
        data = json.load(f)

    print("\n" + "="*80)
    print("  ANÁLISE DE CAMPOS NOVOS - BUBBLE")
    print("="*80)

    for table_name, table_data in data.items():
        print(f"\n{'─'*80}")
        print(f"📊 {table_name.replace('%20', ' ')}")
        print(f"{'─'*80}")

        only_bubble = table_data["only_bubble"]
        only_supabase = table_data["only_supabase"]

        # Normalizar nomes do Supabase para comparação
        normalized_supabase = {normalize_field_name(f): f for f in only_supabase}

        truly_new = []
        renamed = []

        for bubble_field in only_bubble:
            normalized = normalize_field_name(bubble_field)

            # Verificar se é _id (que corresponde a unique_id)
            if bubble_field == "_id":
                renamed.append((bubble_field, "unique_id", "ID do registro"))
                continue

            # Verificar se há correspondente normalizado
            if normalized in normalized_supabase:
                supabase_field = normalized_supabase[normalized]
                renamed.append((bubble_field, supabase_field, "Mesmo campo, nomenclatura diferente"))
            else:
                truly_new.append(bubble_field)

        # Exibir resultados
        if truly_new:
            print(f"\n🆕 CAMPOS REALMENTE NOVOS ({len(truly_new)}):")
            print(f"   Estes campos existem no Bubble mas não têm equivalente no Supabase:\n")
            for field in sorted(truly_new):
                print(f"   ✨ {field}")

            print(f"\n   💡 Ação necessária:")
            print(f"      Adicione estas colunas no Supabase manualmente ou via migration")

        if renamed:
            print(f"\n🔄 Campos com nomenclatura diferente ({len(renamed)}):")
            print(f"   Estes campos já existem no Supabase com outro nome:\n")
            for bubble_field, supabase_field, note in sorted(renamed):
                print(f"   {bubble_field:<30} → {supabase_field:<30} ({note})")

        if not truly_new:
            print(f"\n✅ Nenhum campo realmente novo! Apenas diferenças de nomenclatura.")

    print(f"\n{'='*80}\n")


if __name__ == "__main__":
    analyze_schema_diff()
