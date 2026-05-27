-- Script para adicionar APENAS os campos realmente novos (sem campos de auditoria)
-- Execute no SQL Editor do Supabase Dashboard

-- ============================================================================
-- TABELA: class
-- ============================================================================

-- Contadores de alunos
ALTER TABLE "public"."class"
ADD COLUMN IF NOT EXISTS "current_students_count" integer DEFAULT 0,
ADD COLUMN IF NOT EXISTS "original_students_count" integer DEFAULT 0;

-- ID alternativo do Bubble
ALTER TABLE "public"."class"
ADD COLUMN IF NOT EXISTS "ID" text;

-- Arrays de relacionamentos
ALTER TABLE "public"."class"
ADD COLUMN IF NOT EXISTS "Schedule" jsonb,
ADD COLUMN IF NOT EXISTS "Students" jsonb;

COMMENT ON COLUMN "public"."class"."current_students_count" IS 'Número atual de alunos ativos na turma';
COMMENT ON COLUMN "public"."class"."original_students_count" IS 'Número de alunos quando a turma foi criada';
COMMENT ON COLUMN "public"."class"."ID" IS 'ID alternativo gerado no Bubble';
COMMENT ON COLUMN "public"."class"."Schedule" IS 'Array JSON de IDs dos horários/aulas';
COMMENT ON COLUMN "public"."class"."Students" IS 'Array JSON de IDs dos alunos matriculados';


-- ============================================================================
-- TABELA: programs
-- ============================================================================

-- Programa raiz (hierarquia)
ALTER TABLE "public"."programs"
ADD COLUMN IF NOT EXISTS "os_prog_raiz" text;

-- Referências
ALTER TABLE "public"."programs"
ADD COLUMN IF NOT EXISTS "class" text,
ADD COLUMN IF NOT EXISTS "teacher" text;

-- Lista de instrumentos
ALTER TABLE "public"."programs"
ADD COLUMN IF NOT EXISTS "lista de instrumentos" text;

COMMENT ON COLUMN "public"."programs"."os_prog_raiz" IS 'Referência para programa raiz na hierarquia';
COMMENT ON COLUMN "public"."programs"."class" IS 'Referência para turma associada';
COMMENT ON COLUMN "public"."programs"."teacher" IS 'Referência para professor principal';
COMMENT ON COLUMN "public"."programs"."lista de instrumentos" IS 'Lista de instrumentos disponíveis';


-- ============================================================================
-- TABELA: Sociocultural Profile
-- ============================================================================

-- Campos específicos com nomenclatura do Bubble
ALTER TABLE "public"."Sociocultural Profile"
ADD COLUMN IF NOT EXISTS "Serviços/políticas" text,
ADD COLUMN IF NOT EXISTS "rendimentos/benefícios" text;

COMMENT ON COLUMN "public"."Sociocultural Profile"."Serviços/políticas" IS 'Serviços e políticas públicas';
COMMENT ON COLUMN "public"."Sociocultural Profile"."rendimentos/benefícios" IS 'Rendimentos e benefícios';


-- ============================================================================
-- VERIFICAÇÃO
-- ============================================================================

DO $$
BEGIN
    RAISE NOTICE '✅ Colunas adicionadas com sucesso!';
    RAISE NOTICE '';
    RAISE NOTICE 'Resumo:';
    RAISE NOTICE '  • class: 5 colunas';
    RAISE NOTICE '  • programs: 4 colunas';
    RAISE NOTICE '  • Sociocultural Profile: 2 colunas';
    RAISE NOTICE '';
    RAISE NOTICE 'Total: 11 novas colunas';
END $$;
