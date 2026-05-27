-- Script para adicionar colunas faltantes no Supabase
-- Execute este script no SQL Editor do Supabase Dashboard
-- ou via: psql -h [host] -U postgres -d postgres -f add_missing_columns.sql

-- ============================================================================
-- TABELA: Students
-- ============================================================================

-- Adicionar colunas de auditoria
ALTER TABLE "public"."Students"
ADD COLUMN IF NOT EXISTS "Created By" text,
ADD COLUMN IF NOT EXISTS "Created Date" text;

COMMENT ON COLUMN "public"."Students"."Created By" IS 'ID do usuário que criou o registro no Bubble';
COMMENT ON COLUMN "public"."Students"."Created Date" IS 'Data de criação do registro no Bubble';


-- ============================================================================
-- TABELA: Sociocultural Profile
-- ============================================================================

-- Adicionar colunas de auditoria
ALTER TABLE "public"."Sociocultural Profile"
ADD COLUMN IF NOT EXISTS "Created By" text,
ADD COLUMN IF NOT EXISTS "Created Date" text;

-- Adicionar colunas específicas (com barra no nome)
ALTER TABLE "public"."Sociocultural Profile"
ADD COLUMN IF NOT EXISTS "Serviços/políticas" text,
ADD COLUMN IF NOT EXISTS "rendimentos/benefícios" text;

COMMENT ON COLUMN "public"."Sociocultural Profile"."Created By" IS 'ID do usuário que criou o registro no Bubble';
COMMENT ON COLUMN "public"."Sociocultural Profile"."Created Date" IS 'Data de criação do registro no Bubble';
COMMENT ON COLUMN "public"."Sociocultural Profile"."Serviços/políticas" IS 'Serviços e políticas públicas (campo com formato do Bubble)';
COMMENT ON COLUMN "public"."Sociocultural Profile"."rendimentos/benefícios" IS 'Rendimentos e benefícios (campo com formato do Bubble)';


-- ============================================================================
-- TABELA: class
-- ============================================================================

-- Adicionar colunas de auditoria
ALTER TABLE "public"."class"
ADD COLUMN IF NOT EXISTS "Created By" text,
ADD COLUMN IF NOT EXISTS "Created Date" text,
ADD COLUMN IF NOT EXISTS "Modified Date" text;

-- Adicionar ID alternativo
ALTER TABLE "public"."class"
ADD COLUMN IF NOT EXISTS "ID" text;

-- Adicionar campos relacionais (arrays de IDs)
ALTER TABLE "public"."class"
ADD COLUMN IF NOT EXISTS "Schedule" jsonb,
ADD COLUMN IF NOT EXISTS "Students" jsonb;

-- Adicionar contadores de estudantes
ALTER TABLE "public"."class"
ADD COLUMN IF NOT EXISTS "current_students_count" integer,
ADD COLUMN IF NOT EXISTS "original_students_count" integer;

COMMENT ON COLUMN "public"."class"."Created By" IS 'ID do usuário que criou o registro no Bubble';
COMMENT ON COLUMN "public"."class"."Created Date" IS 'Data de criação do registro no Bubble';
COMMENT ON COLUMN "public"."class"."Modified Date" IS 'Data de última modificação no Bubble';
COMMENT ON COLUMN "public"."class"."ID" IS 'ID alternativo gerado no Bubble';
COMMENT ON COLUMN "public"."class"."Schedule" IS 'Array de IDs dos horários/aulas da turma';
COMMENT ON COLUMN "public"."class"."Students" IS 'Array de IDs dos alunos da turma';
COMMENT ON COLUMN "public"."class"."current_students_count" IS 'Número atual de alunos na turma';
COMMENT ON COLUMN "public"."class"."original_students_count" IS 'Número original de alunos quando a turma foi criada';


-- ============================================================================
-- TABELA: programs
-- ============================================================================

-- Adicionar coluna de auditoria
ALTER TABLE "public"."programs"
ADD COLUMN IF NOT EXISTS "Created By" text;

-- Adicionar campos relacionais
ALTER TABLE "public"."programs"
ADD COLUMN IF NOT EXISTS "class" text,
ADD COLUMN IF NOT EXISTS "teacher" text;

-- Adicionar campos específicos do programa
ALTER TABLE "public"."programs"
ADD COLUMN IF NOT EXISTS "lista de instrumentos" text,
ADD COLUMN IF NOT EXISTS "os_prog_raiz" text,
ADD COLUMN IF NOT EXISTS "patrocinadores" text;

COMMENT ON COLUMN "public"."programs"."Created By" IS 'ID do usuário que criou o registro no Bubble';
COMMENT ON COLUMN "public"."programs"."class" IS 'Referência para turma associada';
COMMENT ON COLUMN "public"."programs"."teacher" IS 'Referência para professor principal';
COMMENT ON COLUMN "public"."programs"."lista de instrumentos" IS 'Lista de instrumentos disponíveis no programa';
COMMENT ON COLUMN "public"."programs"."os_prog_raiz" IS 'Referência para programa raiz (hierarquia)';
COMMENT ON COLUMN "public"."programs"."patrocinadores" IS 'Lista de patrocinadores do programa';


-- ============================================================================
-- VERIFICAÇÃO FINAL
-- ============================================================================

-- Verificar se as colunas foram adicionadas corretamente
DO $$
BEGIN
    RAISE NOTICE '✅ Script executado com sucesso!';
    RAISE NOTICE 'Colunas adicionadas:';
    RAISE NOTICE '  - Students: 2 colunas';
    RAISE NOTICE '  - Sociocultural Profile: 4 colunas';
    RAISE NOTICE '  - class: 8 colunas';
    RAISE NOTICE '  - programs: 6 colunas';
    RAISE NOTICE 'Total: 20 novas colunas';
END $$;
