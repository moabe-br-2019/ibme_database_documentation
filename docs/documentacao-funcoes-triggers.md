# Documentação de Funções e Triggers - IBME

> 📖 **Navegação:** [← Início](./README.md) | [← Estrutura do Banco](./documentacao-banco-dados.md) | [Schema SQL](./schema.sql)

---

## Visão Geral

Este documento explica as funções armazenadas (stored procedures) e triggers (gatilhos) do banco de dados. Elas automatizam processos, validam dados e mantêm a integridade do sistema.

**💡 Pré-requisito:** Se você ainda não conhece a estrutura das tabelas, comece pela [Documentação do Banco de Dados](./documentacao-banco-dados.md).

---

## 📋 Índice por Categoria

### 1. Gerenciamento de Presença (Attendance)
- [bulk_create_schedules](#bulk_create_schedules)
- [bulk_update_attendance](#bulk_update_attendance)
- [bulk_update_attendance_by_student](#bulk_update_attendance_by_student)
- [create_attendance_records](#create_attendance_records)
- [create_attendance_partition](#create_attendance_partition)
- [check_attendance_date_matches_schedule](#check_attendance_date_matches_schedule)
- [update_student_attendance_rate](#update_student_attendance_rate)

### 2. Pesquisas e Estatísticas
- [get_satisfaction_survey](#get_satisfaction_survey)
- [get_satisfaction_counts_filtered](#get_satisfaction_counts_filtered)
- [get_student_survey_stats](#get_student_survey_stats)
- [get_survey_sinta_o_som_stats](#get_survey_sinta_o_som_stats)
- [get_teacher_impact_survey_stats](#get_teacher_impact_survey_stats)
- [get_survey_monitoramento_sinta_som_report](#get_survey_monitoramento_sinta_som_report)
- [get_sinta_som_stats](#get_sinta_som_stats)

### 3. Perfil Sociocultural
- [get_all_sociocultural_stats](#get_all_sociocultural_stats)
- [get_stats_mora_comunidade](#get_stats_mora_comunidade)
- [get_stats_area_risco](#get_stats_area_risco)
- [get_stats_pavimentacao](#get_stats_pavimentacao)
- [get_stats_regiao](#get_stats_regiao)
- [get_stats_renda_familiar](#get_stats_renda_familiar)
- [get_stats_escolaridade_pai](#get_stats_escolaridade_pai)
- [get_stats_escolaridade_mae](#get_stats_escolaridade_mae)
- [get_stats_qtde_moradores](#get_stats_qtde_moradores)
- [get_stats_rendimentos_beneficios](#get_stats_rendimentos_beneficios)
- [get_stats_servicos_politicas](#get_stats_servicos_politicas)
- [get_stats_cursando](#get_stats_cursando)
- [get_stats_recebe_ibme](#get_stats_recebe_ibme)

### 4. Indicadores IBME
- [get_estatisticas_ibme](#get_estatisticas_ibme)

### 5. Utilitários e Processamento de Dados
- [get_student_unique_id_by_name_dob](#get_student_unique_id_by_name_dob)
- [insert_rel_media_survey_monitoramento_sinta_som](#insert_rel_media_survey_monitoramento_sinta_som)
- [delete_expired_invite_codes](#delete_expired_invite_codes)
- [rotate_wake_up](#rotate_wake_up)
- [assign_caravana_to_customer_survey](#assign_caravana_to_customer_survey)
- [students_with_birthday_on](#students_with_birthday_on)

### 6. Triggers Auxiliares
- [normalize_pavimentacao](#normalize_pavimentacao)
- [process_rendimento_beneficios](#process_rendimento_beneficios)
- [process_servicos_politicas](#process_servicos_politicas)
- [set_modified_date](#set_modified_date)
- [update_updated_at_column](#update_updated_at_column)
- [handle_update_student_age](#handle_update_student_age)
- [update_modified_date](#update_modified_date)

---

## 📚 Funções Detalhadas

### Gerenciamento de Presença (Attendance)

#### <a name="bulk_create_schedules"></a>`bulk_create_schedules(p_schedules jsonb)`

**Propósito:** Criar múltiplos agendamentos de aula de uma só vez.

**Como funciona:**
1. Recebe um array JSON com informações de agendamentos
2. Valida que cada agendamento tenha os campos obrigatórios (unique_id, class_id, date, admin)
3. Insere os agendamentos válidos no banco
4. Ignora registros duplicados (mesmo unique_id)
5. Retorna quantos foram inseridos, quantos foram ignorados e os IDs inseridos

**Formato do JSON esperado:**
```json
[
  {
    "unique_id": "abc123",
    "class_id": "turma01",
    "date": "2025-12-30",
    "admin": "admin@example.com",
    "teacher_id": "prof01",
    "duration": 60,
    "presenca_anotada": false
  }
]
```

**Retorna:**
- `inserted_count`: número de registros criados
- `skipped_count`: número de registros ignorados (duplicados ou inválidos)
- `inserted_ids`: array com os IDs dos registros criados

---

#### <a name="bulk_update_attendance"></a>`bulk_update_attendance(attendance_updates jsonb)`

**Propósito:** Atualizar o status de presença de múltiplos alunos de uma só vez.

**Como funciona:**
1. Recebe um array JSON com IDs de presença e novos status
2. Atualiza cada registro de presença correspondente
3. Atualiza automaticamente o campo `updated_at`
4. Retorna quantos registros foram atualizados

**Formato do JSON esperado:**
```json
[
  {
    "id": 123,
    "status": "present",
    "notes": "Chegou no horário"
  },
  {
    "id": 124,
    "status": "absent",
    "notes": null
  }
]
```

**Status possíveis:**
- `present`: Presente
- `absent`: Ausente
- `justified_absence`: Falta justificada

---

#### <a name="bulk_update_attendance_by_student"></a>`bulk_update_attendance_by_student(p_schedule_id text, attendance_updates jsonb)`

**Propósito:** Registrar presença de alunos organizando-os por status (presente, ausente, falta justificada).

**Como funciona:**
1. Busca a data do agendamento
2. Recebe três listas: alunos presentes, ausentes e com falta justificada
3. Valida que nenhum aluno apareça em mais de uma lista
4. Cria ou atualiza os registros de presença (UPSERT)
5. Garante que a data de presença corresponde à data da aula

**Formato do JSON esperado:**
```json
{
  "present": ["aluno01", "aluno02"],
  "justified_absence": ["aluno03"],
  "absent": ["aluno04", "aluno05"]
}
```

**Vantagens:**
- Interface mais intuitiva (organizado por status)
- Validação automática de duplicatas
- Cria registros automaticamente se não existirem

---

#### <a name="create_attendance_records"></a>`create_attendance_records()` - TRIGGER

**Quando é executado:** Automaticamente DEPOIS de inserir um novo agendamento na tabela `schedule`.

**O que faz:**
1. Pega a data e a turma do agendamento criado
2. Busca todos os alunos matriculados naquela turma
3. Cria automaticamente um registro de presença para cada aluno
4. Status inicial: ausente (pode ser atualizado depois)

**Por que é útil:**
Economiza trabalho manual! Ao criar um agendamento, os registros de presença já ficam prontos para serem preenchidos.

---

#### <a name="create_attendance_partition"></a>`create_attendance_partition(year_to_create integer)`

**Propósito:** Criar uma nova partição anual para a tabela de presença.

**Como funciona:**
1. Cria uma tabela particionada para o ano especificado (ex: `attendance_2028`)
2. Define o intervalo de datas (1º de janeiro até 31 de dezembro)
3. Cria índices automáticos para otimizar consultas:
   - Índice por schedule_id
   - Índice por student_id
   - Índice por attendance_date

**Exemplo de uso:**
```sql
SELECT create_attendance_partition(2028);
```

**Por que particionar?**
- Melhora performance em consultas de anos específicos
- Facilita manutenção e arquivamento de dados antigos
- Reduz tempo de backup de períodos específicos

---

#### <a name="check_attendance_date_matches_schedule"></a>`check_attendance_date_matches_schedule()` - TRIGGER

**Quando é executado:** ANTES de inserir ou atualizar um registro na tabela `attendance`.

**O que faz:**
1. Busca a data do agendamento relacionado
2. Se a data de presença vier vazia (NULL), preenche automaticamente com a data da aula
3. Valida que a data de presença corresponde à data da aula
4. Se houver inconsistência, cancela a operação e retorna erro

**Por que é importante:**
Evita erros de dados! Garante que a presença sempre seja registrada na data correta da aula.

---

#### <a name="update_student_attendance_rate"></a>`update_student_attendance_rate()` - FUNÇÃO TRIGGER

**Tipo:** Função definida como trigger, mas atualmente não está ativa/anexada a nenhuma tabela.

**Propósito original:**
1. Calcular a taxa de frequência do aluno
2. Contar presenças + faltas justificadas vs total de aulas
3. Calcular o percentual (arredondado para 2 casas decimais)
4. Atualizar o campo `Attendance Rate` na tabela `Students`

**Fórmula:**
```
Taxa = (Presenças + Faltas Justificadas) / Total de Registros × 100
```

**Exemplo:**
- 8 presenças + 1 falta justificada + 1 falta = 10 aulas
- Taxa = (8 + 1) / 10 × 100 = 90%

**Nota:** Esta função está definida no schema mas não está anexada à tabela `attendance` no momento. O cálculo da taxa de presença pode estar sendo feito de outra forma na aplicação.

---

### Pesquisas e Estatísticas

#### <a name="get_satisfaction_survey"></a>`get_satisfaction_survey(p_city, p_state, p_start_date, p_end_date)`

**Propósito:** Obter dados agregados das pesquisas de satisfação de clientes/comunidade.

**Parâmetros (todos opcionais):**
- `p_city`: Filtrar por cidade
- `p_state`: Filtrar por estado
- `p_start_date`: Data inicial
- `p_end_date`: Data final

**Retorna:** JSON com estatísticas detalhadas das respostas das pesquisas.

---

#### <a name="get_satisfaction_counts_filtered"></a>`get_satisfaction_counts_filtered(...)`

**Propósito:** Contar respostas das pesquisas de satisfação com diversos filtros.

**Parâmetros:**
- Filtros geográficos: `p_city`, `p_state`
- Filtros temporais: `p_start_date`, `p_end_date`
- `p_include_total`: Se deve incluir totais gerais
- `p_sponsor`: Filtra por patrocinador *(novo)*

**Retorna:** JSON com contagens categorizadas das respostas.

---

#### <a name="get_student_survey_stats"></a>`get_student_survey_stats(...)`

**Propósito:** Estatísticas das pesquisas de satisfação respondidas por alunos.

**Parâmetros de filtro:**
- Cidade, estado, turma, programa
- Intervalo de datas
- Opção de incluir totais

**Retorna:** JSON com estatísticas das avaliações dos alunos sobre professores e programa.

**O que analisa:**
- Avaliação dos professores
- Satisfação com as aulas
- Respeito e relacionamento
- Intenção de continuar no programa

---

#### <a name="get_survey_sinta_o_som_stats"></a>`get_survey_sinta_o_som_stats(...)`

**Propósito:** Estatísticas específicas do programa "Sinta o Som" respondidas por alunos.

**Parâmetros:** Similares às outras funções de pesquisa.

**Retorna:** JSON com métricas específicas do programa Sinta o Som.

---

#### <a name="get_teacher_impact_survey_stats"></a>`get_teacher_impact_survey_stats(...)`

**Propósito:** Avaliar o impacto do programa nos professores.

**Versões disponíveis:**
- **Versão 1:** `get_teacher_impact_survey_stats(p_city, p_state, p_program, p_teacher, p_start_date, p_end_date)` - Retorna dados agregados
- **Versão 2:** `get_teacher_impact_survey_stats(p_city, p_state, p_program, p_teacher, p_start_date, p_end_date, p_include_total)` - Permite incluir ou não totais gerais

**Retorna:** Estatísticas sobre como o programa afeta:
- Desenvolvimento profissional dos professores
- Confiança e satisfação
- Impacto na carreira

---

#### <a name="get_survey_monitoramento_sinta_som_report"></a>`get_survey_monitoramento_sinta_som_report(...)`

**Propósito:** Relatório completo de monitoramento do programa Sinta o Som.

**Parâmetros de filtro:**
- Turma, programa, UF, cidade
- Intervalo de datas

**Retorna:** JSON com dados de monitoramento:
- Aplicação da metodologia
- Conteúdo musical e de sustentabilidade
- Entusiasmo dos alunos
- Desafios e necessidades
- Observações dos monitores

---

#### <a name="get_sinta_som_stats"></a>`get_sinta_som_stats(...)`

**Propósito:** Estatísticas gerais do programa Sinta o Som.

**Retorna:** JSON consolidado com todas as métricas do programa.

---

### Perfil Sociocultural

#### <a name="get_all_sociocultural_stats"></a>`get_all_sociocultural_stats(...)`

**Propósito:** Obter TODAS as estatísticas socioculturais em uma única chamada.

**Parâmetros de filtro:**
- Instrumento, gênero, etnia, faixa etária
- Intervalo de datas, status, turmas, programa
- `filter_teacher`: filtra por professor específico *(novo)*
- `filter_sponsor`: filtra por patrocinador específico *(novo)*

**Retorna:** JSON com estatísticas agregadas de:
- Se mora em comunidade
- Área de risco
- Pavimentação
- Região
- Quantidade de moradores
- Renda familiar
- Escolaridade dos pais
- Benefícios recebidos
- Serviços/políticas públicas
- Escolaridade atual
- Bolsas do IBME

**Vantagem:** Uma única função retorna todas as métricas socioculturais, evitando múltiplas chamadas.

---

#### <a name="get_stats_mora_comunidade"></a>`get_stats_mora_comunidade()` (e similares)

**Funções individuais de estatísticas socioculturais:**

Cada uma dessas funções retorna estatísticas específicas sobre um aspecto sociocultural:

1. **get_stats_mora_comunidade**: Quantos alunos moram em comunidades
2. **get_stats_area_risco**: Quantos moram em áreas de risco
3. **get_stats_pavimentacao**: Tipo de pavimentação do endereço
4. **get_stats_regiao**: Distribuição por região
5. **get_stats_renda_familiar**: Faixas de renda familiar
6. **get_stats_escolaridade_pai**: Nível de escolaridade do pai
7. **get_stats_escolaridade_mae**: Nível de escolaridade da mãe
8. **get_stats_qtde_moradores**: Quantidade de pessoas na residência
9. **get_stats_rendimentos_beneficios**: Tipos de benefícios recebidos
10. **get_stats_servicos_politicas**: Serviços públicos acessados
11. **get_stats_cursando**: Nível escolar atual do aluno
12. **get_stats_recebe_ibme**: Se recebe bolsa/auxílio do IBME

**Versões disponíveis:**

Cada função possui duas versões:
- **Versão sem parâmetros:** `get_stats_xxx()` - Retorna estatísticas de todos os alunos
- **Versão com filtros:** `get_stats_xxx(filter_instrument, filter_gender, filter_ethnicity, filter_age_range, filter_date_start, filter_date_end, filter_status, filter_classes, filter_programa, filter_teacher, filter_sponsor)` - Permite filtrar os dados

> **Novos filtros (adicionados em abril/2026):** `filter_teacher` (filtra por professor) e `filter_sponsor` (filtra por patrocinador). Ambos opcionais.

**Formato de retorno (todas):**
```
categoria | quantidade | percentual
----------|------------|------------
"Sim"     | 45         | 75.00
"Não"     | 15         | 25.00
```

**Por que ter funções individuais E uma agregada?**
- Funções individuais: Para dashboards específicos ou filtros detalhados
- Função agregada (`get_all_sociocultural_stats`): Para relatórios completos e visão geral

---

### Indicadores IBME

#### <a name="get_estatisticas_ibme"></a>`get_estatisticas_ibme(filtro_programa)`

**Propósito:** Obter indicadores de impacto do IBME nos alunos.

**Parâmetro:**
- `filtro_programa`: Opcional, filtra por programa específico

**Retorna:** JSON com indicadores de impacto:
- Situação de trabalho atual
- Impacto do IBME na obtenção de trabalho
- Oportunidades internacionais
- Renda familiar e per capita
- Valor de bolsas recebidas
- Impacto econômico das bolsas
- Ensino superior (se está cursando, curso)
- Remuneração extra obtida

**Uso:** Medir o impacto socioeconômico do programa na vida dos alunos.

---

### Utilitários e Processamento de Dados

#### <a name="get_student_unique_id_by_name_dob"></a>`get_student_unique_id_by_name_dob(p_fullname, p_dob)`

**Propósito:** Buscar o ID único de um aluno pelo nome completo e data de nascimento.

**Parâmetros:**
- `p_fullname`: Nome completo do aluno
- `p_dob`: Data de nascimento (formato texto)

**Retorna:** O `unique_id` do aluno

**Uso comum:**
- Importação de dados de planilhas
- Vincular registros de diferentes sistemas
- Evitar duplicatas

---

#### <a name="insert_rel_media_survey_monitoramento_sinta_som"></a>`insert_rel_media_survey_monitoramento_sinta_som(p_survey_unique_id, p_urls)`

**Propósito:** Associar múltiplas URLs de mídia (fotos, vídeos) a uma pesquisa de monitoramento.

**Parâmetros:**
- `p_survey_unique_id`: ID da pesquisa
- `p_urls`: Array de URLs

**Exemplo:**
```sql
SELECT insert_rel_media_survey_monitoramento_sinta_som(
  'survey123',
  ARRAY['https://example.com/foto1.jpg', 'https://example.com/video1.mp4']
);
```

**Uso:** Anexar evidências visuais aos relatórios de monitoramento.

---

#### <a name="delete_expired_invite_codes"></a>`delete_expired_invite_codes()`

**Propósito:** Limpar códigos de convite expirados do sistema.

**Como funciona:**
- Deleta todos os códigos criados há mais de 24 horas
- Deve ser executada periodicamente (via cron job ou similar)

**Por que é necessário:**
- Códigos de convite são temporários
- Evita acúmulo de dados desnecessários
- Melhora segurança (códigos antigos não podem ser usados)

---

#### <a name="rotate_wake_up"></a>`rotate_wake_up()`

**Propósito:** Manter o banco de dados "acordado" em ambientes serverless (como Supabase free tier).

**Como funciona:**
1. Busca o registro mais antigo na tabela `wake_up_supabase`
2. Deleta esse registro
3. Insere um novo registro com timestamp atual
4. Retorna o novo registro criado

**Por que existe:**
- Alguns bancos serverless entram em "hibernação" após inatividade
- Esta função mantém atividade mínima no banco
- Evita cold starts em aplicações críticas

---

#### <a name="assign_caravana_to_customer_survey"></a>`assign_caravana_to_customer_survey(p_cidade, p_estado, p_caravana_unique_id)`

**Propósito:** Vincular retroativamente uma caravana (Sinta o Som) às respostas da `Customer Satisfaction Survey` correspondentes pela localização.

**Parâmetros:**
- `p_cidade`: Cidade onde a caravana ocorreu
- `p_estado`: Estado onde a caravana ocorreu
- `p_caravana_unique_id`: ID único da caravana em `caravana_sinta_o_som`

**Como funciona:**
1. Busca respostas em `Customer Satisfaction Survey` com a mesma cidade/estado (comparação com ILIKE)
2. Atualiza o campo `caravana` nessas respostas com o ID da caravana
3. Retorna quantas linhas foram atualizadas

**Uso típico:**
```sql
SELECT assign_caravana_to_customer_survey('São Paulo', 'SP', 'caravana-abc123');
-- Retorna: 42 (respostas vinculadas)
```

---

#### <a name="students_with_birthday_on"></a>`students_with_birthday_on(p_day, p_month)`

**Propósito:** Listar alunos que fazem aniversário em um dia e mês específicos.

**Parâmetros:**
- `p_day`: Dia do aniversário (inteiro)
- `p_month`: Mês do aniversário (inteiro)

**Retorna:** Tabela com:
- `unique id`: ID do aluno
- `First Name`: Primeiro nome
- `fullname`: Nome completo
- `DOB`: Data de nascimento
- `age`: Idade calculada

**Exemplo de uso:**
```sql
SELECT * FROM students_with_birthday_on(15, 4);
-- Lista alunos que fazem aniversário em 15 de abril
```

---

### Triggers Auxiliares

#### <a name="normalize_pavimentacao"></a>`normalize_pavimentacao()` - FUNÇÃO TRIGGER

**Tipo:** Função definida como trigger, mas atualmente não está ativa/anexada a nenhuma tabela.

**Propósito original:**
1. Remove vírgulas do campo "pavimentação"
2. Remove espaços extras (múltiplos espaços viram um único espaço)
3. Limpa (trim) espaços no início e fim

**Exemplo:**
- Antes: `"  Asfalto  ,    Calçada  "`
- Depois: `"Asfalto Calçada"`

**Nota:** Esta função está definida no schema mas não está anexada à tabela `Sociocultural Profile` no momento. Para ativá-la, seria necessário criar um trigger que a execute.

---

#### <a name="process_rendimento_beneficios"></a>`process_rendimento_beneficios()` - TRIGGER

**Quando é executado:** ANTES de inserir ou atualizar dados na tabela `Sociocultural Profile`.

**O que faz:**
1. Lê o campo texto `rendimentos_beneficios` (formato legado)
2. Converte para o campo JSONB `rendimento_beneficios_array`
3. Remove vírgulas dos valores
4. Se o campo vier vazio, cria um array vazio

**Exemplo de conversão:**
- Input (texto): `'["Bolsa Família", "Vale Alimentação, R$300"]'`
- Output (jsonb): `["Bolsa Família", "Vale Alimentação R$300"]`

**Por que é necessário:** Migração de dados de formato texto para JSONB estruturado.

---

#### <a name="process_servicos_politicas"></a>`process_servicos_politicas()` - TRIGGER

**Quando é executado:** ANTES de inserir ou atualizar dados na tabela `Sociocultural Profile`.

**O que faz:**
1. Lê o campo texto `Serviços_politicas` (formato legado)
2. Converte para JSONB `servicos_politicas_array`
3. Remove texto entre parênteses (geralmente observações)
4. Remove espaços extras
5. Se vazio, cria array vazio

**Exemplo de conversão:**
- Input: `'["SUS (público)", "CRAS", "Escola pública (estadual)"]'`
- Output: `["SUS", "CRAS", "Escola pública"]`

**Por que é necessário:**
- Limpa dados inconsistentes
- Facilita agregações e análises
- Padroniza informações vindas de diferentes fontes

---

#### <a name="set_modified_date"></a>`set_modified_date()` - TRIGGER

**Quando é executado:** ANTES de atualizar um registro (usado em várias tabelas).

**O que faz:** Atualiza automaticamente o campo `modified_date` com a data/hora atual.

**Tabelas que usam:**
- `student_impact_survey`
- E outras que precisam rastrear quando foram modificadas

**Por que é útil:** Auditoria automática - sempre sabemos quando um registro foi alterado pela última vez.

---

#### <a name="update_updated_at_column"></a>`update_updated_at_column()` - TRIGGER

**Quando é executado:** ANTES de atualizar um registro na tabela `attendance`.

**O que faz:** Atualiza automaticamente o campo `updated_at` com o timestamp atual.

**Diferença do `set_modified_date`:**
- `set_modified_date`: usa tipo `DATE` ou `TIMESTAMP`
- `update_updated_at_column`: usa `TIMESTAMP WITH TIME ZONE`

---

#### <a name="handle_update_student_age"></a>`handle_update_student_age()` - FUNÇÃO TRIGGER

**Propósito:** Atualizar automaticamente a idade dos alunos.

**Quando é executado:** Configurado como trigger na tabela `Students` (provavelmente no INSERT/UPDATE ou via cron).

**O que faz:** Recalcula o campo de idade do aluno com base na data de nascimento (`DOB`).

**Por que é útil:** Mantém o campo de idade sempre atualizado sem precisar de atualizações manuais.

---

#### <a name="update_modified_date"></a>`update_modified_date()` - FUNÇÃO TRIGGER

**Propósito:** Atualizar automaticamente o campo `modified_date` com o timestamp atual.

**Semelhante a:** `set_modified_date()` e `update_updated_at_column()` — são variações do mesmo padrão de auditoria.

**Uso:** Aplicado em tabelas que possuem o campo `modified_date` (como `inventory` e `patrimonio`).

---

## 🔗 Mapa de Triggers

### Tabela: `attendance`

| Trigger | Quando | Função | Propósito |
|---------|--------|--------|-----------|
| `trg_check_attendance_date` | BEFORE INSERT/UPDATE | `check_attendance_date_matches_schedule` | Valida consistência de datas |
| `trg_update_attendance_timestamp` | BEFORE UPDATE | `update_updated_at_column` | Atualiza timestamp |

### Tabela: `schedule`

| Trigger | Quando | Função | Propósito |
|---------|--------|--------|-----------|
| `trg_create_attendance_records` | AFTER INSERT | `create_attendance_records` | Cria registros de presença para todos os alunos |

### Tabela: `Sociocultural Profile`

| Trigger | Quando | Função | Propósito |
|---------|--------|--------|-----------|
| `trigger_process_rendimento_beneficios` | BEFORE INSERT/UPDATE | `process_rendimento_beneficios` | Converte texto para JSONB |
| `trigger_process_servicos_politicas` | BEFORE INSERT/UPDATE | `process_servicos_politicas` | Converte e limpa dados |

### Tabela: `student_impact_survey`

| Trigger | Quando | Função | Propósito |
|---------|--------|--------|-----------|
| `trg_student_impact_survey_modified` | BEFORE UPDATE | `set_modified_date` | Atualiza data de modificação |

---

### Tabela: `inventory` e `patrimonio`

| Trigger | Quando | Função | Propósito |
|---------|--------|--------|-----------|
| (via trigger) | BEFORE UPDATE | `update_modified_date` | Atualiza `modified_date` automaticamente |

### Tabela: `Students`

| Trigger | Quando | Função | Propósito |
|---------|--------|--------|-----------|
| (via trigger) | INSERT/UPDATE | `handle_update_student_age` | Recalcula a idade do aluno |

---

### Funções Trigger Não Ativas

As seguintes funções estão definidas como triggers no schema mas não estão atualmente anexadas a nenhuma tabela:

- **`normalize_pavimentacao()`** - Normalizaria o campo pavimentação na tabela `Sociocultural Profile`
- **`update_student_attendance_rate()`** - Calcularia automaticamente a taxa de presença dos alunos

---

## 💡 Fluxos de Trabalho Comuns

### Fluxo 1: Criar Agendamento e Registrar Presença

```
1. Professor/Admin cria agendamento
   ↓
2. TRIGGER: create_attendance_records
   - Cria automaticamente registros para todos os alunos da turma
   - Status inicial: "ausente"
   ↓
3. TRIGGER: check_attendance_date_matches_schedule
   - Preenche attendance_date automaticamente
   - Valida consistência
   ↓
4. Professor marca presença usando bulk_update_attendance_by_student
   ↓
5. Aplicação calcula taxa de presença
   - A taxa é calculada pela aplicação ou por processo externo
   - Atualiza campo na tabela Students conforme necessário
```

### Fluxo 2: Pesquisa de Satisfação

```
1. Sistema gera código de convite
   ↓
2. Aluno/Responsável responde pesquisa
   ↓
3. Dados salvos em student_satisfaction_survey
   ↓
4. Admin consulta estatísticas usando:
   - get_student_survey_stats (dados filtrados)
   - get_satisfaction_survey (dados gerais)
```

### Fluxo 3: Relatório de Impacto Socioeconômico

```
1. Admin solicita relatório
   ↓
2. Sistema chama get_all_sociocultural_stats com filtros
   ↓
3. TRIGGERS: process_rendimento_beneficios e process_servicos_politicas
   - Garantem que dados estão no formato correto (JSONB)
   ↓
4. Função agrega dados de 12 categorias diferentes
   ↓
5. Retorna JSON completo com percentuais e quantidades
```

---

## 🎯 Boas Práticas

### Ao usar funções BULK:

1. **Valide dados antes de enviar**: As funções fazem validação básica, mas validação client-side economiza processamento.

2. **Use transações**: Se criar agendamentos E registrar presença, use BEGIN/COMMIT para garantir atomicidade.

3. **Monitore performance**: Funções bulk são rápidas, mas em lotes muito grandes (>1000 registros), considere dividir.

### Ao trabalhar com triggers:

1. **Não desabilite triggers manualmente**: Eles mantêm integridade dos dados.

2. **Entenda a ordem**: BEFORE triggers rodam antes da inserção, AFTER triggers depois.

3. **Tratamento de erros**: Se um trigger falhar, toda a operação é cancelada (rollback automático).

### Ao criar partições:

1. **Crie partições com antecedência**: Antes do ano começar, crie a partição do próximo ano.

2. **Mantenha partições antigas**: Útil para relatórios históricos.

3. **Monitore uso de espaço**: Partições antigas podem ser arquivadas se não forem mais consultadas.

---

## 🔧 Manutenção Recomendada

### Diário:
- Executar `delete_expired_invite_codes()` via cron job

### Mensal:
- Analisar performance de funções de estatísticas
- Verificar tamanho das partições de attendance

### Anual:
- Criar nova partição de attendance para o próximo ano
- Revisar e otimizar índices

### Conforme necessário:
- Executar `rotate_wake_up()` se usando banco serverless

---

## 📊 Performance e Otimização

### Funções Rápidas (< 100ms):
- `get_student_unique_id_by_name_dob`
- `delete_expired_invite_codes`
- `rotate_wake_up`
- Todos os triggers (executam em microsegundos)

### Funções Moderadas (100ms - 1s):
- `bulk_create_schedules` (depende do tamanho do batch)
- `bulk_update_attendance`
- Funções de estatísticas individuais

### Funções Lentas (> 1s):
- `get_all_sociocultural_stats` (agrega 12 consultas)
- `get_estatisticas_ibme` (cálculos complexos)
- Funções de relatório com muitos filtros

**Dica:** Use caching na aplicação para funções de estatísticas, especialmente se os dados não mudam com frequência.

---

## 🔍 Troubleshooting

### Erro: "Schedule X não encontrado"
- **Causa:** Tentou criar presença para agendamento inexistente
- **Solução:** Verifique se o schedule_id está correto

### Erro: "Data de presença não corresponde à data da aula"
- **Causa:** Tentou inserir attendance_date diferente da data do schedule
- **Solução:** Deixe attendance_date NULL (será preenchido automaticamente) ou use a data correta

### Erro: "Um ou mais alunos aparecem em mais de uma lista"
- **Causa:** Aluno está em "present" E "absent" ao mesmo tempo
- **Solução:** Revise os arrays enviados para bulk_update_attendance_by_student

### Performance lenta em consultas de presença
- **Causa:** Partições podem estar desbalanceadas
- **Solução:** Verifique índices e execute ANALYZE na tabela attendance

---

## 📝 Conclusão

Este conjunto de funções e triggers forma um sistema robusto de automação que:

1. **Reduz trabalho manual**: Triggers criam e atualizam dados automaticamente
2. **Mantém integridade**: Validações garantem consistência
3. **Facilita análises**: Funções de estatísticas retornam dados prontos para dashboards
4. **Otimiza performance**: Particionamento e índices automáticos
5. **Padroniza dados**: Triggers normalizam informações de diferentes fontes

O sistema é projetado para ser **eficiente**, **confiável** e **fácil de manter**, permitindo que administradores e desenvolvedores foquem em funcionalidades de alto nível ao invés de detalhes de banco de dados.

---

## 🔗 Documentação Relacionada

- **[← Estrutura do Banco de Dados](./documentacao-banco-dados.md)** - Entenda as tabelas e relacionamentos
- **[← Voltar ao Início](./README.md)** - Página principal da documentação
- **[Ver Schema SQL](./schema.sql)** - Código SQL completo

---

<div align="center">

**[⬆ Voltar ao topo](#documentação-de-funções-e-triggers---ibme)**

</div>
