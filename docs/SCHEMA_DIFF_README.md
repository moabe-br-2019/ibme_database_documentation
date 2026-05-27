# Análise de Diferenças de Schema - Bubble ↔ Supabase

Scripts para identificar e sincronizar diferenças de schema (colunas) entre Bubble.io e Supabase.

## 📋 Scripts Disponíveis

### 1. `check_schema_diff.py`
Compara os campos/colunas de todas as tabelas entre Bubble e Supabase.

**Uso:**
```bash
python check_schema_diff.py
```

**Output:**
- Lista todos os campos de cada tabela
- Identifica campos que existem apenas no Bubble
- Identifica campos que existem apenas no Supabase
- Gera relatório JSON: `schema_diff_report.json`

### 2. `analyze_new_columns.py`
Analisa o relatório de diferenças e identifica quais campos são **realmente novos** vs **diferenças de nomenclatura**.

**Uso:**
```bash
python analyze_new_columns.py
```

**Output:**
- Separa campos realmente novos
- Identifica campos renomeados (ex: "Created Date" → "created_date")
- Fornece lista clara de ações necessárias

### 3. `add_missing_columns.sql`
Script SQL para adicionar todas as colunas faltantes no Supabase.

## 🚀 Fluxo de Trabalho Completo

### Passo 1: Verificar Diferenças
```bash
python check_schema_diff.py
```

### Passo 2: Analisar Campos Novos
```bash
python analyze_new_columns.py
```

### Passo 3: Adicionar Colunas no Supabase

**Opção A: Via Supabase Dashboard**
1. Acesse o [Supabase Dashboard](https://supabase.com/dashboard)
2. Vá em **SQL Editor**
3. Copie o conteúdo de `add_missing_columns.sql`
4. Cole e execute o script

**Opção B: Via CLI (se estiver usando Supabase local)**
```bash
supabase db execute --file add_missing_columns.sql
```

**Opção C: Via psql**
```bash
psql -h [seu-host].supabase.co -U postgres -d postgres -f add_missing_columns.sql
```

### Passo 4: Verificar Novamente
Após adicionar as colunas, execute novamente para confirmar:
```bash
python check_schema_diff.py
python analyze_new_columns.py
```

## 📊 Campos Identificados (20 novos)

### Students (2 campos)
- `Created By` - ID do usuário que criou o registro
- `Created Date` - Data de criação do registro

### Sociocultural Profile (4 campos)
- `Created By` - ID do usuário que criou o registro
- `Created Date` - Data de criação do registro
- `Serviços/políticas` - Serviços e políticas públicas
- `rendimentos/benefícios` - Rendimentos e benefícios

### class (8 campos)
- `Created By` - ID do usuário que criou
- `Created Date` - Data de criação
- `Modified Date` - Data de última modificação
- `ID` - ID alternativo gerado no Bubble
- `Schedule` - Array de IDs dos horários (jsonb)
- `Students` - Array de IDs dos alunos (jsonb)
- `current_students_count` - Número atual de alunos
- `original_students_count` - Número original de alunos

### programs (6 campos)
- `Created By` - ID do usuário que criou
- `class` - Referência para turma
- `teacher` - Referência para professor
- `lista de instrumentos` - Lista de instrumentos
- `os_prog_raiz` - Programa raiz (hierarquia)
- `patrocinadores` - Lista de patrocinadores

## 🔄 Campos com Nomenclatura Diferente

Estes campos **já existem** no Supabase com nomenclatura diferente (não precisam ser adicionados):

| Bubble | Supabase | Tabela |
|--------|----------|--------|
| `_id` | `unique_id` | Todas |
| `Admin` | `admin` | class |
| `Class Code` | `class_code` | class |
| `Day of week_List` | `day_of_week_list` | class |
| `Duration` | `duration` | class |
| `End date` | `end_date` | class |
| `Instrument_OS` | `instrument_os` | class |
| `Retention Rate` | `retention_rate` | class |
| `Start date` | `start_date` | class |
| `Start time` | `start_time` | class |
| `Assistant` | `assistant` | programs |
| `Bairro` | `bairro` | programs |
| `CEP` | `cep` | programs |
| `Cidade` | `cidade` | programs |
| `Created Date` | `created_date` | programs |
| `Modified Date` | `modified_date` | programs |
| `Rua` | `rua` | programs |
| `UF` | `uf` | programs |

## ⚠️ Importante

### Tipos de Dados
O script SQL usa tipos genéricos (`text`, `jsonb`, `integer`). Você pode querer ajustar para tipos mais específicos:
- Datas: `timestamp with time zone` ou `date`
- IDs: `text` (mantém compatibilidade com IDs do Bubble)
- Arrays: `jsonb` (flexível) ou `text[]` (se for lista simples)

### Arrays no Bubble
Campos como `Schedule` e `Students` são arrays de IDs no Bubble. No SQL estão definidos como `jsonb` para máxima flexibilidade.

### Sincronização Futura
Após adicionar as colunas:
1. Execute `sync_checker.py` para verificar dados
2. Se necessário, crie script de sincronização para popular as novas colunas com dados do Bubble
3. Atualize seus workflows no Bubble para sincronizar esses novos campos

## 🐛 Troubleshooting

### Erro: "coluna já existe"
Se uma coluna já existir, o script usará `ADD COLUMN IF NOT EXISTS`, então não haverá erro. Apenas será ignorada.

### Erro de permissão
Certifique-se de estar usando a `service_role` key do Supabase, não a `anon` key.

### Caracteres especiais nos nomes
Campos com `/` (barra) ou espaços estão entre aspas duplas no SQL. Mantenha as aspas ao referenciar essas colunas.

## 📝 Próximos Passos

Após adicionar as colunas:

1. **Atualizar sync_checker.py** se quiser incluir essas novas colunas na verificação
2. **Criar script de backfill** para popular as novas colunas com dados históricos do Bubble
3. **Atualizar workflows do Bubble** para incluir esses campos na sincronização automática
4. **Documentar** o propósito de cada novo campo

## 🔗 Arquivos Relacionados

- `sync_checker.py` - Verifica sincronização de dados
- `sync_missing_records.py` - Sincroniza registros faltantes
- `schema.sql` - Dump completo do schema do Supabase
- `SYNC_CHECKER_README.md` - Documentação do verificador de sincronização
