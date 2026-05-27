# Script de Verificação de Sincronização Bubble ↔ Supabase

Script Python para verificar a sincronização de dados entre o aplicativo Bubble.io e o banco de dados Supabase do IBME.

## 📋 Tabelas Verificadas

- **Students** (Alunos)
- **Sociocultural Profile** (Perfil Sociocultural)
- **class** (Turmas)
- **programs** (Programas)

## 🚀 Instalação

### 1. Instalar Python (se ainda não tiver)

Certifique-se de ter Python 3.8+ instalado:
```bash
python --version
```

### 2. Instalar dependências

```bash
pip install -r requirements.txt
```

### 3. Configurar variáveis de ambiente

1. Copie o arquivo de exemplo:
   ```bash
   cp .env.example .env
   ```

2. Edite o arquivo `.env` com suas credenciais:
   ```bash
   notepad .env  # No Windows
   ```

#### Como obter as credenciais:

**Bubble API Token:**
1. Acesse seu app no Bubble.io
2. Vá em **Settings** > **API**
3. Clique em **Generate a new API token**
4. Copie o token gerado

**Supabase Credentials:**
1. Acesse seu projeto no [Supabase Dashboard](https://supabase.com/dashboard)
2. Vá em **Settings** > **API**
3. Copie:
   - **URL**: Encontre em "Project URL"
   - **Service Role Key**: Encontre em "service_role" (mantenha seguro!)

## 📊 Uso

### Executar verificação completa:

```bash
python sync_checker.py
```

### O que o script faz:

1. **Compara contagem de registros** entre Bubble e Supabase
2. **Identifica IDs únicos** presentes apenas em um dos sistemas
3. **Gera relatório detalhado** no terminal
4. **Salva relatório JSON** com timestamp para análise posterior

### Exemplo de saída:

```
🔍 ================================================================================
  VERIFICAÇÃO DE SINCRONIZAÇÃO BUBBLE ↔ SUPABASE
  ================================================================================
  Data/Hora: 2026-02-13 15:30:45
  ================================================================================

================================================================================
COMPARAÇÃO DE CONTAGEM DE REGISTROS
================================================================================

Verificando: student...
  Bubble:      6060 registros
  Supabase:    1000 registros
  Status:    ✗ DIFERENÇA
  Diferença: -5060 registros

Verificando: Perfil%20Sociocultural...
  Bubble:      6065 registros
  Supabase:    1000 registros
  Status:    ✗ DIFERENÇA
  Diferença: -5065 registros

...
```

## 🔍 Interpretando os Resultados

### Status "✓ OK"
- As contagens estão idênticas
- Não há necessidade de ação imediata

### Status "✗ DIFERENÇA"
- Há registros diferentes entre os sistemas
- Verifique a seção de IDs únicos para detalhes
- Possíveis causas:
  - Sincronização em andamento
  - Registros deletados em um sistema
  - Falha na sincronização anterior

### IDs Únicos

**"Apenas no Bubble"**: Registros que existem no Bubble mas não no Supabase
- Pode indicar falha na sincronização
- Execute script de sincronização para corrigir

**"Apenas no Supabase"**: Registros que existem no Supabase mas não no Bubble
- Pode indicar registros criados diretamente no banco
- Verifique se são registros legítimos

## 📁 Arquivos Gerados

Cada execução gera um relatório JSON:
```
sync_report_20260213_153045.json
```

Este arquivo contém:
- Contagens detalhadas
- Listas completas de IDs únicos
- Timestamp da execução

## 🔧 Personalização

### Verificar apenas uma tabela:

Edite o arquivo `sync_checker.py` e modifique o `table_mapping`:

```python
self.table_mapping = {
    "student": ("Students", "unique id"),  # Apenas esta tabela
}
```

### Adicionar novas tabelas:

```python
self.table_mapping = {
    "student": ("Students", "unique id"),
    "Perfil%20Sociocultural": ("Sociocultural Profile", "unique id"),
    "classes": ("class", "unique_id"),
    "programs": ("programs", "unique_id"),
    "teachers": ("Teachers", "unique_id"),  # Nova tabela exemplo
}
```

**Nota**: Alguns nomes de tabelas do Bubble usam URL encoding (espaços = %20)

## ⚠️ Segurança

- **NUNCA** commite o arquivo `.env` no git
- O arquivo `.gitignore` já está configurado para ignorá-lo
- A **Service Role Key** do Supabase tem acesso total ao banco
- Mantenha as credenciais seguras

## 🐛 Troubleshooting

### Erro: "Variáveis de ambiente faltando"
- Verifique se o arquivo `.env` existe
- Confirme que todas as variáveis estão preenchidas

### Erro de conexão com Bubble
- Verifique se o token está correto
- Confirme se a API está habilitada no Bubble
- Verifique o nome do app (sem "https://" e sem ".bubbleapps.io")

### Erro de conexão com Supabase
- Verifique a URL do projeto
- Confirme se a Service Role Key está correta
- Verifique se o projeto está ativo

## 📝 Notas

- O script usa paginação automática para lidar com grandes volumes de dados
- O limite padrão é 100 registros por página (limite do Bubble)
- Para melhor performance, execute em horários de menor uso do sistema

## 🤝 Suporte

Para problemas ou dúvidas:
1. Verifique os logs de erro no terminal
2. Consulte o relatório JSON gerado
3. Verifique a documentação da API do Bubble e Supabase
