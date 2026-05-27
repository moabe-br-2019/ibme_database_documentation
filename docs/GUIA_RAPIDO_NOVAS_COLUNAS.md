# Guia Rápido: Adicionar e Sincronizar Novas Colunas

## 📋 Resumo

Adicionar 11 colunas novas do Bubble no Supabase e sincronizar os dados:

### class (5 colunas):
- `current_students_count` - Contador atual de alunos
- `original_students_count` - Contador original de alunos
- `ID` - ID alternativo do Bubble
- `Schedule` - Array de IDs de horários (jsonb)
- `Students` - Array de IDs de alunos (jsonb)

### programs (4 colunas):
- `os_prog_raiz` - Programa raiz (hierarquia)
- `class` - Referência para turma
- `teacher` - Referência para professor
- `lista de instrumentos` - Lista de instrumentos

### Sociocultural Profile (2 colunas):
- `Serviços/políticas` - Serviços públicos
- `rendimentos/benefícios` - Rendimentos

---

## 🚀 PASSO 1: Adicionar Colunas no Supabase

### Opção A: Via Dashboard (Recomendado)

1. Acesse [Supabase Dashboard](https://supabase.com/dashboard)
2. Selecione seu projeto
3. Vá em **SQL Editor** (ícone de código)
4. Abra o arquivo `add_new_fields_only.sql`
5. Copie todo o conteúdo
6. Cole no SQL Editor
7. Clique em **Run** (ou pressione Ctrl+Enter)

### Opção B: Via arquivo

Se preferir, use o arquivo já está pronto:
```
📄 add_new_fields_only.sql
```

---

## 🔄 PASSO 2: Sincronizar Dados do Bubble

Após adicionar as colunas, execute o script Python para popular com dados:

```bash
python sync_new_fields.py
```

### O que o script faz:

1. Busca TODOS os registros do Bubble de cada tabela
2. Extrai apenas os campos novos
3. Atualiza os registros correspondentes no Supabase
4. Mostra progresso e estatísticas

### Tempo estimado:
- class (515 registros): ~30 segundos
- programs (68 registros): ~5 segundos
- Sociocultural Profile (6065 registros): ~2-3 minutos

**Total: ~3-4 minutos**

---

## ✅ PASSO 3: Verificar

Após a sincronização, você pode verificar no Supabase Dashboard:

1. Vá em **Table Editor**
2. Selecione a tabela (ex: `class`)
3. Verifique se as novas colunas aparecem
4. Verifique se os dados foram populados

Ou execute novamente o `check_schema_diff.py`:
```bash
python check_schema_diff.py
```

---

## 🐛 Troubleshooting

### Erro: "coluna não existe" ao sincronizar dados
**Solução**: Execute primeiro o PASSO 1 (adicionar colunas no Supabase)

### Erro: "Timeout" durante sincronização
**Solução**: Normal para tabelas grandes. O script continuará de onde parou.

### Alguns registros não sincronizam
**Solução**: Registros sem os campos no Bubble são pulados automaticamente (é esperado).

### Verificar se as colunas foram adicionadas
Execute no SQL Editor do Supabase:
```sql
-- Verificar colunas da tabela class
SELECT column_name, data_type
FROM information_schema.columns
WHERE table_name = 'class'
  AND column_name IN ('current_students_count', 'original_students_count', 'ID', 'Schedule', 'Students')
ORDER BY column_name;

-- Verificar colunas da tabela programs
SELECT column_name, data_type
FROM information_schema.columns
WHERE table_name = 'programs'
  AND column_name IN ('os_prog_raiz', 'class', 'teacher', 'lista de instrumentos')
ORDER BY column_name;

-- Verificar colunas da tabela Sociocultural Profile
SELECT column_name, data_type
FROM information_schema.columns
WHERE table_name = 'Sociocultural Profile'
  AND column_name IN ('Serviços/políticas', 'rendimentos/benefícios')
ORDER BY column_name;
```

---

## 📊 Verificar Dados Sincronizados

Após sincronização, verifique alguns registros:

```sql
-- Verificar class com os novos campos
SELECT
    unique_id,
    class_code,
    current_students_count,
    original_students_count,
    "ID",
    "Schedule",
    "Students"
FROM "class"
WHERE current_students_count IS NOT NULL
LIMIT 5;

-- Verificar programs
SELECT
    unique_id,
    name,
    os_prog_raiz,
    "class",
    teacher,
    "lista de instrumentos"
FROM programs
WHERE os_prog_raiz IS NOT NULL
LIMIT 5;
```

---

## 📝 Notas Importantes

1. **IF NOT EXISTS**: O SQL usa `IF NOT EXISTS`, então é seguro executar múltiplas vezes
2. **Arrays como JSONB**: Schedule e Students são salvos como JSONB no formato: `["id1", "id2", "id3"]`
3. **NULL é OK**: Se um campo não existir no Bubble, ficará NULL no Supabase
4. **Sem campos de auditoria**: Created By, Created Date, Modified Date NÃO são sincronizados (conforme solicitado)

---

## 🎯 Próximos Passos

Após sincronizar:

1. ✅ Atualizar workflows do Bubble para incluir esses campos na sincronização automática
2. ✅ Testar queries que usam os novos campos
3. ✅ Criar índices se necessário (para campos frequentemente filtrados)
4. ✅ Documentar o propósito de cada campo para a equipe

---

## 📂 Arquivos Criados

```
add_new_fields_only.sql          # SQL para adicionar colunas
sync_new_fields.py               # Script Python para sincronizar dados
GUIA_RAPIDO_NOVAS_COLUNAS.md    # Este guia
```
