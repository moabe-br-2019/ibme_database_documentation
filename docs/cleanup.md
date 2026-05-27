# Cleanup — Sinta o Som (Bubble → replicar no Supabase)

Documento de handoff. Descreve a limpeza de dados já executada no **Bubble**
(`app.ibme.io`) e serve de roteiro para o agente que fará a **mesma limpeza no
Supabase**.

> ⚠️ Operação **destrutiva e irreversível**. A fonte de restauração é o backup
> descrito na seção [Fonte da verdade / backup](#fonte-da-verdade--backup).
> Faça backup do lado do Supabase **antes** de apagar qualquer coisa.

---

## Objetivo

Apagar todos os dados do programa **Sinta o Som** em três níveis — **programas
(polos)**, **turmas** e **alunos** — junto com as matrículas (vínculo
aluno×turma). No Bubble isso já foi feito; falta replicar no Supabase.

## Escopo (o que foi apagado no Bubble)

| Nível | Tipo no Bubble | Qtd | Observação |
|------|----------------|----:|------------|
| Programas / polos | `programs` | **43** | os 43 polos do Sinta o Som |
| Turmas | `classes` | **224** | |
| Alunos | `student` | **3.880** | |
| **Total de registros** | | **4.147** | |
| Matrículas (vínculo aluno×turma) | — | 2.941 | não é "registro" próprio no Bubble (ver abaixo) |

Resultado no Bubble: **4.147 apagados, 0 erros**, confirmado por consulta
registro-a-registro (todos retornam "não existe").

## Modelo de dados / hierarquia

```
programas (polo)  1 ──── N  turmas
     │                        │
     │ N                      │ N
     └──── N  alunos  N ──────┘   (matrícula = relação N:N aluno×turma)
```

Particularidades do Bubble que importam para entender os dados (e que podem ou
não se repetir no Supabase — **confirme o schema real do Supabase**):

- **Programa↔aluno é N:N:** no Bubble o aluno tinha uma *lista* de programas.
- **Turma→programa é 1:N:** cada turma aponta para um único programa.
- **Matrícula aluno×turma:** no Bubble morava **do lado do aluno** (uma lista de
  turmas no aluno); os contadores do lado da turma vinham vazios/zerados. No
  backup essa relação foi materializada na tabela de junção `aluno_turma`
  (2.941 vínculos). No Supabase, espera-se uma tabela de junção / FK equivalente.

## Como foi feito no Bubble

A Data API do Bubble **não tem bulk delete** — então foi um `DELETE` por
registro. Pontos que valem para o Supabase:

1. **Ordem filhos → pais:** `alunos` → `turmas` → `programas`. Apagar os filhos
   antes evita deixar referências órfãs / violar FK.
   No Supabase (Postgres), respeite a mesma ordem **ou** use FKs com
   `ON DELETE CASCADE` / `TRUNCATE ... CASCADE` de forma consciente.
2. **Idempotência:** apagar algo já inexistente é tratado como sucesso (no-op).
3. **Resumível e auditável:** cada deleção foi registrada num ledger
   (`delete_ledger.csv`: timestamp, tipo, id, status, resultado), permitindo
   retomar de onde parou sem reprocessar.
4. **Verificação:** após apagar, conferimos uma amostra registro-a-registro
   (todos "não existem") e que as buscas por programa retornam vazio.

## Fonte da verdade / backup

Antes de apagar, foi feito um **dump completo e re-importável** de cada
registro. Esses arquivos são a fonte para restaurar ou para **identificar quais
linhas apagar no Supabase**:

- `sinta_o_som.sqlite` — banco relacional com as tabelas:
  - `programas` (43) — **agora com todos os campos**: nome, tipo, status,
    endereço (cep, uf, cidade, bairro, rua, número, complemento), descrição,
    patrocinadores, instrumentos, datas, etc.
  - `turmas` (224)
  - `alunos` (3.880)
  - `aluno_turma` (2.941) — junção N:N das matrículas
  - view `v_programa_turma_aluno` — junta os três níveis
- `bubble_backup/programs.jsonl`, `classes.jsonl`, `student.jsonl` — registros
  completos (todos os campos, um JSON por linha), exatamente como vieram da API.
- `bubble_backup/delete_ledger.csv` — log de tudo que foi apagado no Bubble.

> A coluna `id` no `sinta_o_som.sqlite` (e o campo `_id` nos `.jsonl`) é o
> **ID do Bubble**. Se o Supabase guarda esse id (ex.: coluna `bubble_id` ou
> equivalente), use-o para casar as linhas. Se o Supabase tem ids próprios, case
> por chaves alternativas (nome do polo, nome completo do aluno + programa, etc.).

## Roteiro para replicar no Supabase

1. **Backup primeiro.** Dump das tabelas de programas/turmas/alunos/matrículas
   do Supabase (pg_dump ou export por tabela) antes de qualquer `DELETE`.
2. **Mapear o schema:** identifique as tabelas do Supabase equivalentes a
   programas, turmas, alunos e à junção de matrícula, e suas FKs.
3. **Selecionar o escopo:** restrinja às linhas do **Sinta o Som** (mesmos 43
   polos / 224 turmas / 3.880 alunos). Use os ids/nomes do `sinta_o_som.sqlite`
   como lista de referência para não apagar dados de outros programas.
4. **Apagar na ordem filhos → pais:**
   1. matrículas (tabela de junção aluno×turma);
   2. alunos;
   3. turmas;
   4. programas.
   Alternativa: FKs com `ON DELETE CASCADE` apagando a partir dos programas —
   **só se** tiver certeza de que o cascade não atinge dados fora do escopo.
5. **Verificar:** conferir que as contagens zeraram para o escopo do Sinta o Som
   e que não restaram matrículas/turmas/alunos órfãos apontando para os polos
   apagados.

## Cuidado / ponto em aberto

Se os 43 polos forem referenciados por **outros dados fora deste escopo**
(outros alunos, surveys, re-enrollment, etc.), apagá-los deixa essas referências
órfãs. Verifique FKs e dependências no Supabase antes de remover os programas.
