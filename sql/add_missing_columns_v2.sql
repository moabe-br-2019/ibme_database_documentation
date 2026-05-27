-- Script para adicionar colunas faltantes no Supabase (VERSÃO REVISADA)
-- Execute este script no SQL Editor do Supabase Dashboard
--
-- NOTA: Alguns campos do Bubble são sincronizados através de tabelas de relacionamento,
-- não como colunas diretas. Ex: patrocinadores usa a tabela program_patrocinadores

-- ============================================================================
-- TABELA: Students
-- ============================================================================

-- Adicionar colunas de auditoria do Bubble
ALTER TABLE "public"."Students"
ADD COLUMN IF NOT EXISTS "Created By" text,
ADD COLUMN IF NOT EXISTS "Created Date" timestamp with time zone;

COMMENT ON COLUMN "public"."Students"."Created By" IS 'ID do usuário que criou o registro no Bubble';
COMMENT ON COLUMN "public"."Students"."Created Date" IS 'Data/hora de criação do registro no Bubble';


-- ============================================================================
-- TABELA: Sociocultural Profile
-- ============================================================================

-- Adicionar colunas de auditoria do Bubble
ALTER TABLE "public"."Sociocultural Profile"
ADD COLUMN IF NOT EXISTS "Created By" text,
ADD COLUMN IF NOT EXISTS "Created Date" timestamp with time zone;

-- Adicionar campos específicos com nomenclatura do Bubble (mantém compatibilidade)
-- NOTA: Estes campos podem ser variações de campos existentes (Serviços_politicas, rendimentos_beneficios)
ALTER TABLE "public"."Sociocultural Profile"
ADD COLUMN IF NOT EXISTS "Serviços/políticas" text,
ADD COLUMN IF NOT EXISTS "rendimentos/benefícios" text;

COMMENT ON COLUMN "public"."Sociocultural Profile"."Created By" IS 'ID do usuário que criou o registro no Bubble';
COMMENT ON COLUMN "public"."Sociocultural Profile"."Created Date" IS 'Data/hora de criação do registro no Bubble';
COMMENT ON COLUMN "public"."Sociocultural Profile"."Serviços/políticas" IS 'Serviços e políticas públicas (formato Bubble com barra)';
COMMENT ON COLUMN "public"."Sociocultural Profile"."rendimentos/benefícios" IS 'Rendimentos e benefícios (formato Bubble com barra)';


-- ============================================================================
-- TABELA: class
-- ============================================================================

-- Adicionar colunas de auditoria do Bubble
ALTER TABLE "public"."class"
ADD COLUMN IF NOT EXISTS "Created By" text,
ADD COLUMN IF NOT EXISTS "Created Date" timestamp with time zone,
ADD COLUMN IF NOT EXISTS "Modified Date" timestamp with time zone;

-- Adicionar ID alternativo do Bubble
ALTER TABLE "public"."class"
ADD COLUMN IF NOT EXISTS "ID" text;

-- Adicionar arrays de relacionamentos (Schedule e Students são arrays de IDs no Bubble)
ALTER TABLE "public"."class"
ADD COLUMN IF NOT EXISTS "Schedule" jsonb,
ADD COLUMN IF NOT EXISTS "Students" jsonb;

-- Adicionar contadores de alunos (CONFIRMADO como campos novos)
ALTER TABLE "public"."class"
ADD COLUMN IF NOT EXISTS "current_students_count" integer DEFAULT 0,
ADD COLUMN IF NOT EXISTS "original_students_count" integer DEFAULT 0;

COMMENT ON COLUMN "public"."class"."Created By" IS 'ID do usuário que criou o registro no Bubble';
COMMENT ON COLUMN "public"."class"."Created Date" IS 'Data/hora de criação do registro no Bubble';
COMMENT ON COLUMN "public"."class"."Modified Date" IS 'Data/hora de última modificação no Bubble';
COMMENT ON COLUMN "public"."class"."ID" IS 'ID alternativo gerado no Bubble (formato: 0477250216)';
COMMENT ON COLUMN "public"."class"."Schedule" IS 'Array JSON de IDs dos horários/aulas da turma (referências a outra tabela)';
COMMENT ON COLUMN "public"."class"."Students" IS 'Array JSON de IDs dos alunos matriculados (referências a Students)';
COMMENT ON COLUMN "public"."class"."current_students_count" IS 'Número atual de alunos ativos na turma';
COMMENT ON COLUMN "public"."class"."original_students_count" IS 'Número de alunos quando a turma foi criada';


-- ============================================================================
-- TABELA: programs
-- ============================================================================

-- Adicionar coluna de auditoria do Bubble
ALTER TABLE "public"."programs"
ADD COLUMN IF NOT EXISTS "Created By" text;

-- Adicionar campos relacionais
-- NOTA: class e teacher são referências a outras tabelas
ALTER TABLE "public"."programs"
ADD COLUMN IF NOT EXISTS "class" text,
ADD COLUMN IF NOT EXISTS "teacher" text;

-- Adicionar campos específicos do programa
ALTER TABLE "public"."programs"
ADD COLUMN IF NOT EXISTS "lista de instrumentos" text,
ADD COLUMN IF NOT EXISTS "os_prog_raiz" text;

-- NOTA: patrocinadores NÃO é adicionado aqui pois existe a tabela de relacionamento
-- program_patrocinadores que gerencia a relação N:N entre programs e sponsors

COMMENT ON COLUMN "public"."programs"."Created By" IS 'ID do usuário que criou o registro no Bubble';
COMMENT ON COLUMN "public"."programs"."class" IS 'Referência para turma associada (FK para class)';
COMMENT ON COLUMN "public"."programs"."teacher" IS 'Referência para professor principal (FK para professores)';
COMMENT ON COLUMN "public"."programs"."lista de instrumentos" IS 'Lista/array de instrumentos disponíveis no programa';
COMMENT ON COLUMN "public"."programs"."os_prog_raiz" IS 'Referência para programa raiz na hierarquia de programas';


-- ============================================================================
-- ÍNDICES RECOMENDADOS (Opcional - descomente se necessário)
-- ============================================================================

-- Criar índices para campos frequentemente filtrados
-- CREATE INDEX IF NOT EXISTS idx_class_current_students_count ON "public"."class"("current_students_count");
-- CREATE INDEX IF NOT EXISTS idx_class_original_students_count ON "public"."class"("original_students_count");
-- CREATE INDEX IF NOT EXISTS idx_programs_os_prog_raiz ON "public"."programs"("os_prog_raiz");

-- Criar índices para campos de auditoria se forem usados em queries
-- CREATE INDEX IF NOT EXISTS idx_students_created_date ON "public"."Students"("Created Date");
-- CREATE INDEX IF NOT EXISTS idx_class_created_date ON "public"."class"("Created Date");


-- ============================================================================
-- VERIFICAÇÃO FINAL
-- ============================================================================

DO $$
DECLARE
    col_count integer;
BEGIN
    -- Contar colunas adicionadas
    SELECT COUNT(*)
    INTO col_count
    FROM information_schema.columns
    WHERE table_schema = 'public'
    AND (
        (table_name = 'Students' AND column_name IN ('Created By', 'Created Date'))
        OR (table_name = 'Sociocultural Profile' AND column_name IN ('Created By', 'Created Date', 'Serviços/políticas', 'rendimentos/benefícios'))
        OR (table_name = 'class' AND column_name IN ('Created By', 'Created Date', 'Modified Date', 'ID', 'Schedule', 'Students', 'current_students_count', 'original_students_count'))
        OR (table_name = 'programs' AND column_name IN ('Created By', 'class', 'teacher', 'lista de instrumentos', 'os_prog_raiz'))
    );

    RAISE NOTICE '════════════════════════════════════════════════════════';
    RAISE NOTICE '✅ Script executado com sucesso!';
    RAISE NOTICE '════════════════════════════════════════════════════════';
    RAISE NOTICE 'Colunas verificadas/adicionadas:';
    RAISE NOTICE '  - Students: 2 colunas (Created By, Created Date)';
    RAISE NOTICE '  - Sociocultural Profile: 4 colunas';
    RAISE NOTICE '  - class: 8 colunas (incluindo current/original_students_count)';
    RAISE NOTICE '  - programs: 5 colunas (incluindo os_prog_raiz)';
    RAISE NOTICE '';
    RAISE NOTICE '📋 Total esperado: 19 colunas';
    RAISE NOTICE '📋 Encontradas no schema: %', col_count;
    RAISE NOTICE '';
    RAISE NOTICE 'NOTAS IMPORTANTES:';
    RAISE NOTICE '  • patrocinadores NÃO foi adicionado - usa tabela program_patrocinadores';
    RAISE NOTICE '  • Arrays (Schedule, Students) salvos como jsonb';
    RAISE NOTICE '  • Datas como timestamp with time zone';
    RAISE NOTICE '════════════════════════════════════════════════════════';
END $$;
