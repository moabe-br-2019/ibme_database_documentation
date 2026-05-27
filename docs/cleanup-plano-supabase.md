# Plano de ação — Apagar os dados do Sinta o Som no **Supabase**

> **Meu plano de ação (Claude).** O documento descreve o que vou executar para
> replicar no **Supabase** a limpeza que já foi feita no **Bubble** (`app.ibme.io`).
> Status: limpeza no Bubble **concluída** (4.147 registros, 0 erros). Falta o Supabase.
> Complementa o handoff em [`cleanup.md`](./cleanup.md).

> ⚠️ **Operação destrutiva e irreversível.** Nada é apagado sem backup do lado do
> Supabase e sem sua confirmação explícita **fase a fase**. A fonte de
> restauração/escopo é o backup descrito em
> [Fonte da verdade](#fonte-da-verdade--escopo).

---

## Objetivo

Apagar todos os dados do programa **Sinta o Som** no Supabase, em três níveis —
**programas (polos)**, **turmas** e **alunos** — junto com as matrículas
(vínculo aluno×turma) e os registros dependentes (surveys, presenças, etc.).

| Nível | Tabela no Supabase | Qtd no escopo | Chave (id do Bubble) |
|------|--------------------|----:|----|
| Programas / polos | `public.programs` | **43** | `unique_id` |
| Turmas | `public.class` | **224** | `unique_id` |
| Alunos | `public."Students"` | **3.880** | `"unique id"` |
| Matrícula aluno×turma | — (embutida em `Students."Classes"`) | 2.941 | — |

Total apagado no Bubble: **4.147 registros, 0 erros**. O Supabase tem **8.082**
alunos no total — o Sinta o Som é só uma fatia, então **o escopo precisa ser
restrito por id**, nunca um `TRUNCATE` cego.

## Modelo de dados real no Supabase

```
programs (unique_id)  1 ──< class (unique_id, program)
     ▲                          ▲
     │ Programa                 │ Classes
     └───── Students ("unique id", "Programa", "Classes") ──┘
```

Particularidades que mudam o plano em relação ao Bubble:

- **Matrícula NÃO é tabela de junção no Supabase.** Mora na coluna
  `Students."Classes"` (texto, id da turma) — e `Students."Programa"` (id do
  polo). Logo, **apagar a linha do aluno já remove a matrícula**; não há
  `aluno_turma` para limpar à parte (diferente do backup SQLite).
- **Referências são `text` no estilo Bubble**, não FKs reais. Pela inspeção do
  `schema.sql` **não há `FOREIGN KEY` / `ON DELETE CASCADE`** nessas relações.
  Consequência: o Postgres **não** vai cascatear nem bloquear — os órfãos são
  responsabilidade nossa. Por isso a ordem filhos → pais e a limpeza dos
  dependentes têm de ser explícitas.

### Junções de programa (limpar junto)

| Tabela | Coluna de escopo |
|--------|------------------|
| `public.program_classes` | `program_id`, `class_unique_id` |
| `public.program_teachers` | `program_id` |
| `public.program_patrocinadores` | `program_id` |
| `public.program_instruments` | `program_id` |

### Dependentes a confirmar AO VIVO (referenciam aluno/turma/programa por id-texto)

Candidatos identificados no `schema.sql` (lista **não** exaustiva — confirmar na
Fase 1 com introspecção do banco real):

- Por **aluno** (`student` / `student_id` = `Students."unique id"`):
  `attendance` (particionada por ano), `"Rate students"`, `"Sociocultural Profile"`,
  `student_impact_survey`, `student_satisfaction_survey`, `parent_satisfaction_survey`,
  `funarte_avaliacao_aluno`, `students_invite_code`, `perfil_sociocultural`…
- Por **turma** (`class_id` = `class.unique_id`): `schedule`, `program_classes`.
- Por **programa** (`program_id` = `programs.unique_id`): as 4 junções acima.

## Fonte da verdade / escopo

A lista autoritativa de **quais linhas apagar** vem do backup do Bubble (não de
uma query no Supabase). Casar por id do Bubble:

- `data/sinta_o_som.sqlite` — `programas` (43), `turmas` (224), `alunos` (3.880),
  `aluno_turma` (2.941), view `v_programa_turma_aluno`.
- `bubble_backup/*.jsonl` — registros completos como vieram da API.
- `bubble_backup/delete_ledger.csv` — o que foi apagado no Bubble.

> O `id` no SQLite (= `_id` nos `.jsonl`) é o **id do Bubble**. No Supabase ele
> corresponde a `programs.unique_id`, `class.unique_id` e `Students."unique id"`.
> Casar por esse id. Se algum não casar, usar chave alternativa (nome do polo,
> nome completo do aluno + programa) e **registrar a divergência** antes de apagar.

---

## Plano de execução (fase a fase, com confirmação)

### Fase 0 — Pré-requisitos e BACKUP (bloqueante)
1. Confirmar credenciais (`.env`) e que aponto para o projeto certo
   (`test_connection.py` → Supabase OK).
2. **Backup do Supabase antes de qualquer `DELETE`:** `pg_dump` (ou export por
   tabela) de `programs`, `class`, `"Students"`, as 4 junções de programa e todos
   os dependentes confirmados na Fase 1. Guardar com timestamp em `logs/` ou fora
   do repo. **Sem backup verificado, não prossigo.**

### Fase 1 — Descoberta ao vivo do schema
Não confiar só no `schema.sql` (pode estar defasado). Rodar no banco real:
1. Listar FKs reais (se houver):
   ```sql
   SELECT conrelid::regclass AS tabela, confrelid::regclass AS referencia, conname
   FROM pg_constraint WHERE contype = 'f'
     AND confrelid::regclass::text IN ('programs','class','"Students"');
   ```
2. Enumerar **toda** coluna que referencia aluno/turma/programa por texto:
   ```sql
   SELECT table_name, column_name FROM information_schema.columns
   WHERE table_schema='public'
     AND column_name IN ('student','student_id','class_id','class_unique_id',
                         'program','program_id','Programa','Classes');
   ```
3. Consolidar a lista definitiva de tabelas/colunas dependentes.

### Fase 2 — Montar as listas de escopo
1. Extrair do `data/sinta_o_som.sqlite` os ids: `programas.id` (43),
   `turmas.id` (224), `alunos.id` (3.880).
2. Carregar em tabelas temporárias no Postgres
   (`tmp_scope_programs/classes/students`) para usar nos `WHERE ... IN (...)`.
3. Conferir casamento: quantos ids do escopo existem de fato em cada tabela do
   Supabase (esperado ≈ contagens da tabela acima). Reportar faltantes.

### Fase 3 — Dry-run (contagens, **sem apagar**)
Para cada tabela-alvo e cada dependente, rodar o `SELECT count(*)` equivalente ao
`DELETE` planejado e apresentar o total que **seria** apagado. Validar contra os
números esperados (43 / 224 / 3.880 + dependentes). **Só sigo após você revisar
estes números.**

### Fase 4 — Execução na ordem filhos → pais (idempotente + ledger)
Tudo dentro de transações por fase, registrando cada passo num ledger
(`logs/supabase_delete_ledger.csv`: timestamp, tabela, escopo, linhas_afetadas,
status). Idempotente (apagar inexistente = no-op). Ordem:

1. **Dependentes do aluno** — `attendance` (todas as partições), surveys, ratings,
   perfil sociocultural, invite codes… `WHERE student IN (tmp_scope_students)`.
2. **Dependentes da turma** — `schedule` `WHERE class_id IN (tmp_scope_classes)`.
3. **Junções de programa** — `program_classes`, `program_teachers`,
   `program_patrocinadores`, `program_instruments`
   `WHERE program_id IN (tmp_scope_programs)`.
4. **Alunos** — `DELETE FROM "Students" WHERE "unique id" IN (tmp_scope_students)`
   (remove também a matrícula embutida em `"Classes"`).
5. **Turmas** — `DELETE FROM class WHERE unique_id IN (tmp_scope_classes)`.
6. **Programas** — `DELETE FROM programs WHERE unique_id IN (tmp_scope_programs)`.

> **Não** usar `TRUNCATE` nem `CASCADE` — o escopo é parcial e há dados de outros
> programas nas mesmas tabelas.

### Fase 5 — Verificação
1. Contagens zeradas para o escopo em cada nível (43/224/3.880 → 0).
2. Sem órfãos: nenhuma linha em dependentes/junções aponta para ids apagados.
   ```sql
   SELECT count(*) FROM class      WHERE program IN (tmp_scope_programs);   -- 0
   SELECT count(*) FROM "Students" WHERE "Programa" IN (tmp_scope_programs); -- 0
   ```
3. Total de alunos cai de **8.082** para **~4.202** (8.082 − 3.880), confirmando
   que só o Sinta o Som saiu.
4. Gravar relatório final em `logs/`.

## Rollback
Restaurar a partir do dump da Fase 0 (re-`INSERT` das linhas afetadas). Como o
backup do Bubble (`.jsonl` / SQLite) é re-importável, ele é o último recurso.

## Cuidados / pontos em aberto
- **Polos/alunos compartilhados:** se algum dos 43 polos ou 3.880 alunos for
  referenciado por dados **fora** do Sinta o Som (outros surveys, re-enrollment,
  patrimônio, etc.), apagá-los deixa órfãos. A Fase 1 tem de mapear isso e a
  Fase 3 (dry-run) tem de expor antes de eu apagar qualquer coisa.
- **`attendance` é particionada por ano** (`attendance_2024..2027`, `_default`) —
  apagar em todas as partições pelo `student_id` no escopo.
- **Sem FK real** = sem rede de proteção do banco; a ordem e a verificação manual
  são o que garante consistência.
