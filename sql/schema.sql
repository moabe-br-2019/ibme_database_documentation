

SET statement_timeout = 0;
SET lock_timeout = 0;
SET idle_in_transaction_session_timeout = 0;
SET client_encoding = 'UTF8';
SET standard_conforming_strings = on;
SELECT pg_catalog.set_config('search_path', '', false);
SET check_function_bodies = false;
SET xmloption = content;
SET client_min_messages = warning;
SET row_security = off;


CREATE SCHEMA IF NOT EXISTS "public";


ALTER SCHEMA "public" OWNER TO "pg_database_owner";


COMMENT ON SCHEMA "public" IS 'standard public schema';



CREATE TYPE "public"."attendance_status" AS ENUM (
    'present',
    'absent',
    'justified_absence'
);


ALTER TYPE "public"."attendance_status" OWNER TO "postgres";


CREATE TYPE "public"."condition_status" AS ENUM (
    'new',
    'good',
    'fair',
    'poor',
    'under_maintenance',
    'retired'
);


ALTER TYPE "public"."condition_status" OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."assign_caravana_to_customer_survey"("p_cidade" "text", "p_estado" "text", "p_caravana_unique_id" "text") RETURNS integer
    LANGUAGE "plpgsql"
    AS $$
DECLARE
  v_rows_updated integer;
BEGIN
  UPDATE public."Customer Satisfaction Survey"
  SET caravana = p_caravana_unique_id
  WHERE ("Cidade" ILIKE p_cidade OR ("Cidade" IS NULL AND p_cidade IS NULL))
    AND ("Estado" ILIKE p_estado OR ("Estado" IS NULL AND p_estado IS NULL));

  GET DIAGNOSTICS v_rows_updated = ROW_COUNT;
  RETURN v_rows_updated;
END;
$$;


ALTER FUNCTION "public"."assign_caravana_to_customer_survey"("p_cidade" "text", "p_estado" "text", "p_caravana_unique_id" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."bulk_create_schedules"("p_schedules" "jsonb") RETURNS TABLE("inserted_count" integer, "skipped_count" integer, "inserted_ids" "text"[])
    LANGUAGE "plpgsql"
    AS $$
begin
  /*
    Espera p_schedules como JSON array, ex:
    [
      {"unique_id":"...", "class_id":"...", "date":"2025-12-30", "admin":"...", "teacher_id":"...", "duration":60, "presenca_anotada":false},
      ...
    ]
  */

  with input as (
    select *
    from jsonb_to_recordset(p_schedules) as x(
      unique_id text,
      class_id text,
      date date,
      admin text,
      teacher_id text,
      duration numeric,
      presenca_anotada boolean,
      att_rate numeric
    )
  ),
  valid as (
    select *
    from input
    where unique_id is not null
      and class_id is not null
      and date is not null
      and admin is not null
  ),
  ins as (
    insert into public.schedule (unique_id, class_id, date, admin, teacher_id, duration, presenca_anotada, att_rate)
    select
      unique_id, class_id, date, admin, teacher_id, duration,
      coalesce(presenca_anotada, false),
      att_rate
    from valid
    on conflict (unique_id) do nothing
    returning unique_id
  )
  select
    (select count(*) from ins)::int as inserted_count,
    (select count(*) from valid)::int - (select count(*) from ins)::int as skipped_count,
    (select coalesce(array_agg(unique_id), array[]::text[]) from ins) as inserted_ids
  into inserted_count, skipped_count, inserted_ids;

  return next;
end;
$$;


ALTER FUNCTION "public"."bulk_create_schedules"("p_schedules" "jsonb") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."bulk_update_attendance"("attendance_updates" "jsonb") RETURNS TABLE("updated_count" integer, "failed_ids" bigint[])
    LANGUAGE "plpgsql"
    AS $$
declare
  v_updated_count integer;
  v_failed_ids bigint[] := array[]::bigint[];
begin
  -- Fazer update em massa
  with updates as (
    select 
      (value->>'id')::bigint as attendance_id,
      (value->>'status')::attendance_status as new_status,
      value->>'notes' as new_notes
    from jsonb_array_elements(attendance_updates)
  )
  update attendance a
  set 
    status = u.new_status,
    notes = coalesce(u.new_notes, a.notes),
    updated_at = now()
  from updates u
  where a.id = u.attendance_id;
  
  get diagnostics v_updated_count = row_count;
  
  return query select v_updated_count, v_failed_ids;
end;
$$;


ALTER FUNCTION "public"."bulk_update_attendance"("attendance_updates" "jsonb") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."bulk_update_attendance_by_student"("p_schedule_id" "text", "attendance_updates" "jsonb") RETURNS TABLE("affected_count" integer, "failed_students" "text"[])
    LANGUAGE "plpgsql"
    AS $$
declare
  v_schedule_date date;
  v_present text[] := array[]::text[];
  v_justified text[] := array[]::text[];
  v_absent text[] := array[]::text[];
  v_overlap_count int;
begin
  -- schedule date (fonte da verdade)
  select s.date into v_schedule_date
  from public.schedule s
  where s.unique_id = p_schedule_id;

  if v_schedule_date is null then
    raise exception 'Schedule % não encontrado', p_schedule_id;
  end if;

  -- Extrair arrays do JSON (se não vier, vira array vazio)
  select coalesce(array_agg(x), array[]::text[]) into v_present
  from jsonb_array_elements_text(coalesce(attendance_updates->'present','[]'::jsonb)) as t(x);

  select coalesce(array_agg(x), array[]::text[]) into v_justified
  from jsonb_array_elements_text(coalesce(attendance_updates->'justified_absence','[]'::jsonb)) as t(x);

  select coalesce(array_agg(x), array[]::text[]) into v_absent
  from jsonb_array_elements_text(coalesce(attendance_updates->'absent','[]'::jsonb)) as t(x);

  -- Validação simples: ninguém pode estar em 2 listas ao mesmo tempo
  select count(*) into v_overlap_count
  from (
    select unnest(v_present) as id
    intersect
    select unnest(v_justified)
    union all
    select unnest(v_present)
    intersect
    select unnest(v_absent)
    union all
    select unnest(v_justified)
    intersect
    select unnest(v_absent)
  ) o;

  if v_overlap_count > 0 then
    raise exception 'Um ou mais alunos aparecem em mais de uma lista (present/justified_absence/absent).';
  end if;

  -- UPSERT em massa (cria ou atualiza)
  with desired as (
    select unnest(v_present)   as student_id, 'present'::public.attendance_status            as status
    union all
    select unnest(v_justified) as student_id, 'justified_absence'::public.attendance_status as status
    union all
    select unnest(v_absent)    as student_id, 'absent'::public.attendance_status             as status
  )
  insert into public.attendance (schedule_id, student_id, status, attendance_date)
  select p_schedule_id, d.student_id, d.status, v_schedule_date
  from desired d
  on conflict on constraint attendance_unique_student_per_schedule_date
  do update set
    status = excluded.status,
    updated_at = now();

  get diagnostics affected_count = row_count;

  return query select affected_count, array[]::text[];

exception
  when others then
    return query select 0, array['error: ' || sqlerrm];
end;
$$;


ALTER FUNCTION "public"."bulk_update_attendance_by_student"("p_schedule_id" "text", "attendance_updates" "jsonb") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."check_attendance_date_matches_schedule"() RETURNS "trigger"
    LANGUAGE "plpgsql"
    AS $$
DECLARE
  v_schedule_date date;
BEGIN
  -- Busca a data do schedule
  SELECT s.date INTO v_schedule_date
  FROM schedule s
  WHERE s.unique_id = NEW.schedule_id;

  -- Schedule não existe (FK já vai pegar, mas vamos ser explícitos)
  IF v_schedule_date IS NULL THEN
    RAISE EXCEPTION 'Schedule % não encontrado', NEW.schedule_id;
  END IF;

  -- Se attendance_date veio NULL, autocompleta
  IF NEW.attendance_date IS NULL THEN
    NEW.attendance_date := v_schedule_date;
    RAISE NOTICE 'attendance_date preenchido automaticamente: %', v_schedule_date;
  END IF;

  -- Valida consistência
  IF NEW.attendance_date <> v_schedule_date THEN
    RAISE EXCEPTION 
      'Data de presença (%) não corresponde à data da aula (%). Schedule: %',
      NEW.attendance_date, v_schedule_date, NEW.schedule_id;
  END IF;

  RETURN NEW;
END;
$$;


ALTER FUNCTION "public"."check_attendance_date_matches_schedule"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."create_attendance_partition"("year_to_create" integer) RETURNS "void"
    LANGUAGE "plpgsql"
    AS $$
DECLARE
  partition_name text;
  start_date date;
  end_date date;
BEGIN
  partition_name := 'attendance_' || year_to_create;
  start_date := make_date(year_to_create, 1, 1);
  end_date := make_date(year_to_create + 1, 1, 1);
  
  EXECUTE format(
    'CREATE TABLE IF NOT EXISTS %I PARTITION OF attendance FOR VALUES FROM (%L) TO (%L)',
    partition_name, start_date, end_date
  );
  
  EXECUTE format('CREATE INDEX IF NOT EXISTS idx_%I_schedule ON %I(schedule_id)', partition_name, partition_name);
  EXECUTE format('CREATE INDEX IF NOT EXISTS idx_%I_student ON %I(student_id)', partition_name, partition_name);
  EXECUTE format('CREATE INDEX IF NOT EXISTS idx_%I_date ON %I(attendance_date)', partition_name, partition_name);
END;
$$;


ALTER FUNCTION "public"."create_attendance_partition"("year_to_create" integer) OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."create_attendance_records"() RETURNS "trigger"
    LANGUAGE "plpgsql"
    AS $$declare
  schedule_date date;
begin
  -- schedule.date já é DATE, não precisa timezone
  select s.date
    into schedule_date
  from public.schedule s
  where s.unique_id = new.unique_id;

  if schedule_date is null then
    raise exception 'Schedule % não encontrado ou sem data', new.unique_id;
  end if;

  insert into public.attendance (schedule_id, student_id, attendance_date)
  select 
    new.unique_id,
    st."unique id",
    schedule_date
  from public."Students" st
  where st."Classes" = new.class_id
  on conflict on constraint attendance_unique_student_per_schedule_date
  do nothing;

  return new;
end;$$;


ALTER FUNCTION "public"."create_attendance_records"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."delete_expired_invite_codes"() RETURNS "void"
    LANGUAGE "plpgsql" SECURITY DEFINER
    AS $$
begin
  delete from public.students_invite_code
  where created_date < now() - interval '24 hours';
end;
$$;


ALTER FUNCTION "public"."delete_expired_invite_codes"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."get_all_sociocultural_stats"("filter_instrument" "text" DEFAULT NULL::"text", "filter_gender" "text" DEFAULT NULL::"text", "filter_ethnicity" "text" DEFAULT NULL::"text", "filter_age_range" "text" DEFAULT NULL::"text", "filter_date_start" "text" DEFAULT NULL::"text", "filter_date_end" "text" DEFAULT NULL::"text", "filter_status" "text" DEFAULT NULL::"text", "filter_classes" "text" DEFAULT NULL::"text", "filter_programa" "text" DEFAULT NULL::"text", "filter_teacher" "text" DEFAULT NULL::"text", "filter_sponsor" "text" DEFAULT NULL::"text") RETURNS "jsonb"
    LANGUAGE "plpgsql"
    AS $$
DECLARE
    resultado jsonb;
BEGIN
    SELECT jsonb_build_object(
        'mora_em_comunidade', (SELECT jsonb_agg(row_to_json(t)) FROM get_stats_mora_comunidade(filter_instrument, filter_gender, filter_ethnicity, filter_age_range, filter_date_start, filter_date_end, filter_status, filter_classes, filter_programa, filter_teacher, filter_sponsor) t),
        'area_de_risco', (SELECT jsonb_agg(row_to_json(t)) FROM get_stats_area_risco(filter_instrument, filter_gender, filter_ethnicity, filter_age_range, filter_date_start, filter_date_end, filter_status, filter_classes, filter_programa, filter_teacher, filter_sponsor) t),
        'pavimentacao', (SELECT jsonb_agg(row_to_json(t)) FROM get_stats_pavimentacao(filter_instrument, filter_gender, filter_ethnicity, filter_age_range, filter_date_start, filter_date_end, filter_status, filter_classes, filter_programa, filter_teacher, filter_sponsor) t),
        'regiao', (SELECT jsonb_agg(row_to_json(t)) FROM get_stats_regiao(filter_instrument, filter_gender, filter_ethnicity, filter_age_range, filter_date_start, filter_date_end, filter_status, filter_classes, filter_programa, filter_teacher, filter_sponsor) t),
        'qtde_moradores', (SELECT jsonb_agg(row_to_json(t)) FROM get_stats_qtde_moradores(filter_instrument, filter_gender, filter_ethnicity, filter_age_range, filter_date_start, filter_date_end, filter_status, filter_classes, filter_programa, filter_teacher, filter_sponsor) t),
        'rendimentos_beneficios', (SELECT jsonb_agg(row_to_json(t)) FROM get_stats_rendimentos_beneficios(filter_instrument, filter_gender, filter_ethnicity, filter_age_range, filter_date_start, filter_date_end, filter_status, filter_classes, filter_programa, filter_teacher, filter_sponsor) t),
        'servicos_politicas', (SELECT jsonb_agg(row_to_json(t)) FROM get_stats_servicos_politicas(filter_instrument, filter_gender, filter_ethnicity, filter_age_range, filter_date_start, filter_date_end, filter_status, filter_classes, filter_programa, filter_teacher, filter_sponsor) t),
        'cursando', (SELECT jsonb_agg(row_to_json(t)) FROM get_stats_cursando(filter_instrument, filter_gender, filter_ethnicity, filter_age_range, filter_date_start, filter_date_end, filter_status, filter_classes, filter_programa, filter_teacher, filter_sponsor) t),
        'renda_familiar', (SELECT jsonb_agg(row_to_json(t)) FROM get_stats_renda_familiar(filter_instrument, filter_gender, filter_ethnicity, filter_age_range, filter_date_start, filter_date_end, filter_status, filter_classes, filter_programa, filter_teacher, filter_sponsor) t),
        'escolaridade_pai', (SELECT jsonb_agg(row_to_json(t)) FROM get_stats_escolaridade_pai(filter_instrument, filter_gender, filter_ethnicity, filter_age_range, filter_date_start, filter_date_end, filter_status, filter_classes, filter_programa, filter_teacher, filter_sponsor) t),
        'escolaridade_mae', (SELECT jsonb_agg(row_to_json(t)) FROM get_stats_escolaridade_mae(filter_instrument, filter_gender, filter_ethnicity, filter_age_range, filter_date_start, filter_date_end, filter_status, filter_classes, filter_programa, filter_teacher, filter_sponsor) t),
        'recebe_ibme', (SELECT jsonb_agg(row_to_json(t)) FROM get_stats_recebe_ibme(filter_instrument, filter_gender, filter_ethnicity, filter_age_range, filter_date_start, filter_date_end, filter_status, filter_classes, filter_programa, filter_teacher, filter_sponsor) t)
    ) INTO resultado;

    RETURN resultado;
END;
$$;


ALTER FUNCTION "public"."get_all_sociocultural_stats"("filter_instrument" "text", "filter_gender" "text", "filter_ethnicity" "text", "filter_age_range" "text", "filter_date_start" "text", "filter_date_end" "text", "filter_status" "text", "filter_classes" "text", "filter_programa" "text", "filter_teacher" "text", "filter_sponsor" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."get_estatisticas_ibme"("filtro_programa" "text" DEFAULT NULL::"text") RETURNS "jsonb"
    LANGUAGE "plpgsql"
    AS $$
DECLARE
    v_total_registros integer;
    v_json_resultado  jsonb;
    v_filtro          text;
BEGIN
    -----------------------------------------------------------------
    -- 1) Normalização do filtro
    -----------------------------------------------------------------
    v_filtro := nullif(trim(filtro_programa), '');

    -----------------------------------------------------------------
    -- 2) Contagem total de alunos (universo)
    -----------------------------------------------------------------
    SELECT count(DISTINCT i.student)
    INTO v_total_registros
    FROM public.indicadores_ibme i
    LEFT JOIN public."Students" s ON i.student = s."unique id"
    WHERE (v_filtro IS NULL OR s."Programa" = v_filtro);

    IF v_total_registros = 0 THEN
        RETURN jsonb_build_object(
            'message', 'Nenhum dado encontrado para este filtro',
            'filtros_aplicados', v_filtro
        );
    END IF;

    -----------------------------------------------------------------
    -- 3) CTE base com dados filtrados
    -----------------------------------------------------------------
    WITH dados_filtrados AS (
        SELECT 
            i.*,
            i.student AS student_id
        FROM public.indicadores_ibme i
        LEFT JOIN public."Students" s ON i.student = s."unique id"
        WHERE (v_filtro IS NULL OR s."Programa" = v_filtro)
    )
    SELECT jsonb_build_object(

        -----------------------------------------------------------------
        -- META
        -----------------------------------------------------------------
        'meta', jsonb_build_object(
            'total_alunos',      v_total_registros,
            'programa_filtrado', coalesce(v_filtro, 'Todos')
        ),

        -----------------------------------------------------------------
        -- MÉDIAS
        -----------------------------------------------------------------
        'medias', (
            SELECT jsonb_build_object(
                'renda_familiar_num',        round(avg(p3_q1_renda_familiar_num::numeric), 2),
                'qtd_pessoas',               round(avg(p3_q2_qtd_pessoas::numeric), 2),
                'valor_bolsa',               round(avg(p3_qt3_vlr_bolsa::numeric), 2),
                'renda_per_capita',          round(avg(renda_per_capita_geral::numeric), 2),
                'impacto_bolsa_fam',         round(avg(p3_q4_impacto_bolsa_familia::numeric), 2),
                'impacto_bolsa_per_capita',  round(avg(p3_q5_impacto_bolsa_per_capita::numeric), 2)
            )
            FROM dados_filtrados
        ),

        -----------------------------------------------------------------
        -- DISTRIBUIÇÕES
        -----------------------------------------------------------------
        'distribuicao', jsonb_build_object(

            -------------------------------------------------------------
            -- RENDA FAMILIAR (TXT)
            -------------------------------------------------------------
            'renda_familiar', (
                WITH opcoes AS (
                    SELECT unnest(ARRAY[
                        'Nenhuma renda',
                        'Até 1 salário mínimo',
                        'De 1 a 3 salários mínimos',
                        'De 3 a 6 salários mínimos',
                        'De 6 a 9 salários mínimos',
                        'De 9 a 12 salários mínimos',
                        'Acima de 12 salários mínimos'
                    ]) AS opcao_fixa
                ),
                respostas AS (
                    SELECT
                        trim(p3_q1_renda_familiar_txt) AS opcao,
                        student_id
                    FROM dados_filtrados
                    WHERE p3_q1_renda_familiar_txt IS NOT NULL
                      AND trim(p3_q1_renda_familiar_txt) <> ''
                )
                SELECT jsonb_agg(
                    jsonb_build_object(
                        'resposta',    o.opcao_fixa,
                        'qtd',         COALESCE(r.qtd, 0),
                        'porcentagem', round(COALESCE(r.qtd, 0) * 100.0 / v_total_registros, 2)
                    )
                )
                FROM opcoes o
                LEFT JOIN (
                    SELECT opcao, count(DISTINCT student_id) AS qtd
                    FROM respostas
                    GROUP BY opcao
                ) r ON r.opcao = o.opcao_fixa
            ),

            -------------------------------------------------------------
            -- TRABALHO ATUAL
            -------------------------------------------------------------
            'trabalho_atual', (
                WITH opcoes AS (
                    SELECT unnest(ARRAY[
                        'Sim como MEI / prestadora de serviços',
                        'Sim com contrato formal (CLT)',
                        'Sim como bolsista / estagiária remunerada',
                        'Sim de forma eventual (cachês ou apresentações esporádicas)',
                        'Não estou atuando profissionalmente na área da música'
                    ]) AS opcao_fixa
                ),
                respostas AS (
                    SELECT trim(value) AS opcao, student_id
                    FROM dados_filtrados,
                         unnest(string_to_array(p1_q1_trabalho_atual, ',')) AS value
                )
                SELECT jsonb_agg(
                    jsonb_build_object(
                        'resposta',    o.opcao_fixa,
                        'qtd',         COALESCE(r.qtd, 0),
                        'porcentagem', round(COALESCE(r.qtd, 0) * 100.0 / v_total_registros, 2)
                    )
                )
                FROM opcoes o
                LEFT JOIN (
                    SELECT opcao, count(DISTINCT student_id) AS qtd
                    FROM respostas
                    GROUP BY opcao
                ) r ON r.opcao = o.opcao_fixa
            ),

            -------------------------------------------------------------
            -- OPORTUNIDADE INTERNACIONAL
            -------------------------------------------------------------
            'oportunidade_internacional', (
                WITH opcoes AS (
                    SELECT unnest(ARRAY[
                        'Sim participei de uma turnê internacional',
                        'Sim participei de masterclasses com professores estrangeiros',
                        'Sim participei de um curso, intercâmbio ou residência artística internacional',
                        'Ainda não mas estou em processo de seleção para uma oportunidade internacional',
                        'Não participei de nenhuma oportunidade internacional até o momento'
                    ]) AS opcao_fixa
                ),
                respostas AS (
                    SELECT trim(value) AS opcao, student_id
                    FROM dados_filtrados,
                         unnest(string_to_array(p2_q1_oportunidade_internacional, ',')) AS value
                )
                SELECT jsonb_agg(
                    jsonb_build_object(
                        'resposta',    o.opcao_fixa,
                        'qtd',         COALESCE(r.qtd, 0),
                        'porcentagem', round(COALESCE(r.qtd, 0) * 100.0 / v_total_registros, 2)
                    )
                )
                FROM opcoes o
                LEFT JOIN (
                    SELECT opcao, count(DISTINCT student_id) AS qtd
                    FROM respostas
                    GROUP BY opcao
                ) r ON r.opcao = o.opcao_fixa
            ),

            -------------------------------------------------------------
            -- CURSO DE MÚSICA
            -------------------------------------------------------------
            'curso_musica', (
                WITH opcoes AS (
                    SELECT unnest(ARRAY[
                        'Sim em curso técnico de música',
                        'Sim em curso de extensão / formação complementar',
                        'Sim em curso de graduação (licenciatura ou bacharelado)',
                        'Sim em curso de pós-graduação / especialização',
                        'Não ainda não me matriculei em nenhum novo curso'
                    ]) AS opcao_fixa
                ),
                respostas AS (
                    SELECT trim(value) AS opcao, student_id
                    FROM dados_filtrados,
                         unnest(string_to_array(p8_q1_curso_musica, ',')) AS value
                )
                SELECT jsonb_agg(
                    jsonb_build_object(
                        'resposta',    o.opcao_fixa,
                        'qtd',         COALESCE(r.qtd, 0),
                        'porcentagem', round(COALESCE(r.qtd, 0) * 100.0 / v_total_registros, 2)
                    )
                )
                FROM opcoes o
                LEFT JOIN (
                    SELECT opcao, count(DISTINCT student_id) AS qtd
                    FROM respostas
                    GROUP BY opcao
                ) r ON r.opcao = o.opcao_fixa
            ),

            -------------------------------------------------------------
            -- REMUNERAÇÃO EXTRA
            -------------------------------------------------------------
            'remuneracao_extra', (
                WITH opcoes AS (
                    SELECT unnest(ARRAY[
                        'Sim recebo uma bolsa regular por minha atuação musical (projeto orquestra estágio etc.)',
                        'Sim recebo cachês por apresentações ocasionais (concertos eventos gravações etc.)',
                        'Sim recebo remuneração fixa por trabalho musical contínuo (escola orquestra grupo etc.)',
                        'Ainda não mas já recebi alguma remuneração esporádica',
                        'Não ainda não recebo nenhum tipo de remuneração por atividades musicais'
                    ]) AS opcao_fixa
                ),
                respostas AS (
                    SELECT trim(value) AS opcao, student_id
                    FROM dados_filtrados,
                         unnest(string_to_array(p4_q1_remuneracao_extra, ',')) AS value
                )
                SELECT jsonb_agg(
                    jsonb_build_object(
                        'resposta',    o.opcao_fixa,
                        'qtd',         COALESCE(r.qtd, 0),
                        'porcentagem', round(COALESCE(r.qtd, 0) * 100.0 / v_total_registros, 2)
                    )
                )
                FROM opcoes o
                LEFT JOIN (
                    SELECT opcao, count(DISTINCT student_id) AS qtd
                    FROM respostas
                    GROUP BY opcao
                ) r ON r.opcao = o.opcao_fixa
            )
        )
    ) INTO v_json_resultado;

    RETURN v_json_resultado;
END;
$$;


ALTER FUNCTION "public"."get_estatisticas_ibme"("filtro_programa" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."get_satisfaction_counts_filtered"("p_city" "text" DEFAULT NULL::"text", "p_end_date" "date" DEFAULT NULL::"date", "p_include_total" boolean DEFAULT true, "p_start_date" "date" DEFAULT NULL::"date", "p_state" "text" DEFAULT NULL::"text", "p_sponsor" "text" DEFAULT NULL::"text") RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
declare
    result jsonb := '{}'::jsonb;
    q record;
    o record;
    sql_base text;
    sql_count text;
    total_global int := 0;
    total_global_filtered int := 0;
    total_question_filtered int := 0;
    total_question_unfiltered int := 0;  -- NOVO: total sem filtros
    count_value numeric := 0;
begin
    -- 1) TOTAIS GLOBAIS
    execute 'select count(*) from public."Customer Satisfaction Survey"' into total_global;

    -- Base da query com possível JOIN para filtro de patrocinador
    if p_sponsor is not null then
        sql_base := 'from public."Customer Satisfaction Survey" s
                     inner join public."caravana_sinta_o_som" c
                     on s."caravana" = c."unique_id"
                     where 1=1';
    else
        sql_base := 'from public."Customer Satisfaction Survey" s where 1=1';
    end if;

    -- Filtro por cidade
    if p_city is not null then
        sql_base := sql_base || format(' and s."Cidade" = %L', p_city);
    end if;

    -- Filtro por estado
    if p_state is not null then
        sql_base := sql_base || format(' and s."Estado" = %L', p_state);
    end if;

    -- Filtro por data inicial
    if p_start_date is not null then
        sql_base := sql_base || format(' and s."Creation Date" >= %L::date', p_start_date);
    end if;

    -- Filtro por data final
    if p_end_date is not null then
        sql_base := sql_base || format(' and s."Creation Date" <= %L::date', p_end_date);
    end if;

    -- Filtro por patrocinador (NOVO)
    if p_sponsor is not null then
        sql_base := sql_base || format(' and c."patrocinador" = %L', p_sponsor);
    end if;

    -- Total filtrado global
    execute 'select count(*) ' || sql_base into total_global_filtered;

    -- 2) LOOP PELAS PERGUNTAS
    for q in (
        select * from (values
            ('1_sustentabilidade'),
            ('2_Acesso_Formação_Musical'),
            ('3_Impacto_Pessoal_Comunitário'),
            ('4_Projeção_de_Futuro'),
            ('6_exposicao_arte')
        ) as t(question)
    ) loop

        -- Conta respostas válidas (não nulas) PARA ESTA PERGUNTA (COM FILTROS)
        execute 'select count(*) ' || sql_base || format(' and s.%I is not null', q.question)
            into total_question_filtered;

        -- Conta respostas válidas (não nulas) PARA ESTA PERGUNTA (SEM FILTROS)
        execute format('select count(*) from public."Customer Satisfaction Survey" s where s.%I is not null', q.question)
            into total_question_unfiltered;

        total_question_filtered := coalesce(total_question_filtered, 0);
        total_question_unfiltered := coalesce(total_question_unfiltered, 0);
        result := jsonb_set(result, array[q.question], '[]'::jsonb, true);

        -- 3) LOOP PELAS OPÇÕES DE RESPOSTA
        for o in (
            select * from (
                values
                    ('Nunca participei', 1, '6_exposicao_arte'),
                    ('Há menos de 1 ano', 2, '6_exposicao_arte'),
                    ('Há mais de 1 ano', 3, '6_exposicao_arte'),
                    ('Não me lembro', 4, '6_exposicao_arte'),
                    ('Concordo totalmente', 1, 'padrao'),
                    ('Concordo parcialmente', 2, 'padrao'),
                    ('Discordo parcialmente', 3, 'padrao'),
                    ('Discordo totalmente', 4, 'padrao')
            ) as t(opt_name, rank, grupo)
            where (q.question = '6_exposicao_arte' and grupo = '6_exposicao_arte')
               or (q.question <> '6_exposicao_arte' and grupo = 'padrao')
            order by rank
        ) loop

            -- Conta quantas respostas desta opção (COM FILTROS)
            sql_count := 'select count(*) ' || sql_base || format(' and s.%I = %L', q.question, o.opt_name);
            execute sql_count into count_value;
            count_value := coalesce(count_value, 0);

            -- Adiciona ao resultado com todos os campos
            result := jsonb_set(
                result,
                array[q.question],
                (
                    result -> q.question
                    || jsonb_build_object(
                            'option', o.opt_name,
                            'count', count_value,  -- NOVO: quantidade absoluta
                            'percent',
                                case when total_question_filtered = 0 then 0
                                     else round((count_value / total_question_filtered) * 100, 2)
                                end,
                            'total_responses', total_question_unfiltered,  -- NOVO: total sem filtros
                            'total_filtered', total_question_filtered  -- NOVO: total com filtros
                        )
                )::jsonb,
                false
            );
        end loop;
    end loop;

    -- 4) ADICIONA TOTAIS (SE p_include_total = true)
    if coalesce(p_include_total, true) then
        result := result || jsonb_build_object(
            'total_count_global', coalesce(total_global, 0),
            'total_filtered_global', coalesce(total_global_filtered, 0)
        );
    end if;

    return result;
end;
$$;


ALTER FUNCTION "public"."get_satisfaction_counts_filtered"("p_city" "text", "p_end_date" "date", "p_include_total" boolean, "p_start_date" "date", "p_state" "text", "p_sponsor" "text") OWNER TO "postgres";


COMMENT ON FUNCTION "public"."get_satisfaction_counts_filtered"("p_city" "text", "p_end_date" "date", "p_include_total" boolean, "p_start_date" "date", "p_state" "text", "p_sponsor" "text") IS 'Retorna estatísticas agregadas da pesquisa de satisfação com filtros opcionais incluindo patrocinador.
Versão 2.1 - Adicionados campos count, total_responses e total_filtered para melhor detalhamento.';



CREATE OR REPLACE FUNCTION "public"."get_satisfaction_survey"("p_city" "text" DEFAULT NULL::"text", "p_state" "text" DEFAULT NULL::"text", "p_start_date" "date" DEFAULT NULL::"date", "p_end_date" "date" DEFAULT NULL::"date") RETURNS "jsonb"
    LANGUAGE "plpgsql"
    AS $$
declare
  result jsonb := '{}'::jsonb;
  q record;
  o record;
  sql_base text;
  sql text;
  total int;
  count_value numeric;
begin
  -- Loop em cada pergunta da pesquisa
  for q in (
    select * from (values
      ('1_sustentabilidade'),
      ('2_Acesso_Formação_Musical'),
      ('3_Impacto_Pessoal_Comunitário'),
      ('4_Projeção_de_Futuro')
    ) as t(question)
  ) loop

    -- SQL base com filtros opcionais
    sql_base := format('FROM "Customer Satisfaction Survey" s WHERE s.%I IS NOT NULL', q.question);

    if p_city is not null then
      sql_base := sql_base || format(' AND s."Cidade" = %L', p_city);
    end if;

    if p_state is not null then
      sql_base := sql_base || format(' AND s."Estado" = %L', p_state);
    end if;

    if p_start_date is not null then
      sql_base := sql_base || format(' AND s."Creation Date" >= %L::date', p_start_date);
    end if;

    if p_end_date is not null then
      sql_base := sql_base || format(' AND s."Creation Date" <= %L::date', p_end_date);
    end if;

    -- Total por pergunta
    execute 'SELECT count(*) ' || sql_base into total;
    if total is null then total := 0; end if;

    result := jsonb_set(result, array[q.question], '[]'::jsonb);

    -- Loop pelas opções oficiais
    for o in (
      select option, rank from "Customer Satisfaction Survey options" order by rank
    ) loop
      sql := 'SELECT count(*) ' || sql_base || format(' AND s.%I = %L', q.question, o.option);
      execute sql into count_value;

      -- Adiciona ao JSON final
      result := jsonb_set(
        result,
        array[q.question],
        (
          result -> q.question
          || jsonb_build_object(
               'option', o.option,
               'percent',
               case when total = 0 then 0
                    else round((count_value/total)*100, 2)
               end
             )
        )::jsonb,
        false
      );
    end loop;
  end loop;

  return result;
end;
$$;


ALTER FUNCTION "public"."get_satisfaction_survey"("p_city" "text", "p_state" "text", "p_start_date" "date", "p_end_date" "date") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."get_sinta_som_stats"("p_city" "text" DEFAULT NULL::"text", "p_state" "text" DEFAULT NULL::"text", "p_start_date" "date" DEFAULT NULL::"date", "p_end_date" "date" DEFAULT NULL::"date", "p_include_total" boolean DEFAULT false) RETURNS "jsonb"
    LANGUAGE "plpgsql"
    AS $$
DECLARE
  result jsonb := '{}'::jsonb;
  q record;
  o record;
  sql_base text;
  sql text;
  total_global int;
  total_global_filtered int;
  total_question_filtered int;
  count_value numeric;
BEGIN
  -- Total global SEM filtros
  EXECUTE 'SELECT count(*) FROM "Survey_Masterclass_Sinta_Som"' INTO total_global;
  IF total_global IS NULL THEN total_global := 0; END IF;

  -- Total global COM filtros
  sql_base := 'FROM "Survey_Masterclass_Sinta_Som" s WHERE 1=1';
  IF p_city IS NOT NULL THEN sql_base := sql_base || format(' AND s.cidade = %L', p_city); END IF;
  IF p_state IS NOT NULL THEN sql_base := sql_base || format(' AND s.estado = %L', p_state); END IF;
  IF p_start_date IS NOT NULL THEN sql_base := sql_base || format(' AND s.created_at >= %L::date', p_start_date); END IF;
  IF p_end_date IS NOT NULL THEN sql_base := sql_base || format(' AND s.created_at <= %L::date', p_end_date); END IF;

  EXECUTE 'SELECT count(*) ' || sql_base INTO total_global_filtered;
  IF total_global_filtered IS NULL THEN total_global_filtered := 0; END IF;

  -- Loop das perguntas
  FOR q IN (
    SELECT * FROM (VALUES
      ('kp1_pergunta_1'),
      ('kp1_pergunta_2'),
      ('kp1_pergunta_3'),
      ('kp1_pergunta_4'),
      ('kp1_pergunta_5'),
      ('kp1_pergunta_6'),
      ('kp2_pergunta_1'),
      ('kp2_pergunta_2'),
      ('kp2_pergunta_3'),
      ('kp2_pergunta_4')
    ) AS t(question)
  ) LOOP

    EXECUTE 'SELECT count(*) ' || sql_base || format(' AND s.%I IS NOT NULL', q.question)
    INTO total_question_filtered;
    IF total_question_filtered IS NULL THEN total_question_filtered := 0; END IF;

    result := jsonb_set(result, ARRAY[q.question], '[]'::jsonb, true);

    FOR o IN (
      SELECT option, rank
      FROM "Customer Satisfaction Survey options"
      ORDER BY rank
    ) LOOP

      sql := 'SELECT count(*) ' || sql_base || format(' AND s.%I = %L', q.question, o.option);
      EXECUTE sql INTO count_value;

      result := jsonb_set(
        result, ARRAY[q.question],
        (
          result -> q.question
          || jsonb_build_object(
              'option', o.option,
              'percent',
                CASE WHEN total_question_filtered = 0 THEN 0
                     ELSE round((count_value / total_question_filtered) * 100, 2)
                END,
              'total_filtered', total_question_filtered
            )
        )::jsonb,
        false
      );
    END LOOP;
  END LOOP;

  -- Totais globais
  result := result || jsonb_build_object(
    'total_count', total_global,
    'total_filtered', total_global_filtered
  );

  RETURN result;
END;
$$;


ALTER FUNCTION "public"."get_sinta_som_stats"("p_city" "text", "p_state" "text", "p_start_date" "date", "p_end_date" "date", "p_include_total" boolean) OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."get_stats_area_risco"() RETURNS TABLE("categoria" "text", "quantidade" bigint, "percentual" numeric)
    LANGUAGE "plpgsql"
    AS $$
DECLARE
    total_valido bigint;
BEGIN
    SELECT COUNT(*) INTO total_valido 
    FROM "Sociocultural Profile" 
    WHERE "Área de risco" IS NOT NULL AND "Área de risco" != '';
    
    RETURN QUERY
    SELECT 
        "Área de risco" as categoria,
        COUNT(*) as quantidade,
        ROUND((COUNT(*) * 100.0 / NULLIF(total_valido, 0)), 2) as percentual
    FROM "Sociocultural Profile"
    WHERE "Área de risco" IS NOT NULL AND "Área de risco" != ''
    GROUP BY "Área de risco"
    ORDER BY COUNT(*) DESC;
END;
$$;


ALTER FUNCTION "public"."get_stats_area_risco"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."get_stats_area_risco"("filter_instrument" "text" DEFAULT NULL::"text", "filter_gender" "text" DEFAULT NULL::"text", "filter_ethnicity" "text" DEFAULT NULL::"text", "filter_age_range" "text" DEFAULT NULL::"text", "filter_date_start" "text" DEFAULT NULL::"text", "filter_date_end" "text" DEFAULT NULL::"text", "filter_status" "text" DEFAULT NULL::"text", "filter_classes" "text" DEFAULT NULL::"text", "filter_programa" "text" DEFAULT NULL::"text", "filter_teacher" "text" DEFAULT NULL::"text", "filter_sponsor" "text" DEFAULT NULL::"text") RETURNS TABLE("categoria" "text", "quantidade" bigint, "percentual" integer)
    LANGUAGE "plpgsql"
    AS $$
DECLARE
    total_valido bigint;
    where_clause text := 'WHERE sp."Área de risco" IS NOT NULL AND sp."Área de risco" != ''''';
BEGIN
    IF filter_instrument IS NOT NULL THEN
        where_clause := where_clause || ' AND s."Instrument_Enroll_Form" = ' || quote_literal(filter_instrument);
    END IF;
    IF filter_gender IS NOT NULL THEN
        where_clause := where_clause || ' AND s."Gender" = ' || quote_literal(filter_gender);
    END IF;
    IF filter_ethnicity IS NOT NULL THEN
        where_clause := where_clause || ' AND s."Ethnicity" = ' || quote_literal(filter_ethnicity);
    END IF;
    IF filter_age_range IS NOT NULL THEN
        CASE filter_age_range
            WHEN '0-6' THEN where_clause := where_clause || ' AND s."Age_Number" BETWEEN 0 AND 6';
            WHEN '7-12' THEN where_clause := where_clause || ' AND s."Age_Number" BETWEEN 7 AND 12';
            WHEN '13-17' THEN where_clause := where_clause || ' AND s."Age_Number" BETWEEN 13 AND 17';
            WHEN '18-29' THEN where_clause := where_clause || ' AND s."Age_Number" BETWEEN 18 AND 29';
            WHEN '30-59' THEN where_clause := where_clause || ' AND s."Age_Number" BETWEEN 30 AND 59';
            WHEN '60+' THEN where_clause := where_clause || ' AND s."Age_Number" >= 60';
        END CASE;
    END IF;
    IF filter_date_start IS NOT NULL THEN
        where_clause := where_clause || ' AND s."Creation Date"::date >= ' || quote_literal(filter_date_start);
    END IF;
    IF filter_date_end IS NOT NULL THEN
        where_clause := where_clause || ' AND s."Creation Date"::date <= ' || quote_literal(filter_date_end);
    END IF;
    IF filter_status IS NOT NULL THEN
        where_clause := where_clause || ' AND s."Status" = ' || quote_literal(filter_status);
    END IF;
    IF filter_classes IS NOT NULL THEN
        where_clause := where_clause || ' AND s."Classes" = ' || quote_literal(filter_classes);
    END IF;
    IF filter_programa IS NOT NULL THEN
        where_clause := where_clause || ' AND s."Programa" = ' || quote_literal(filter_programa);
    END IF;
    IF filter_teacher IS NOT NULL THEN
        where_clause := where_clause || ' AND EXISTS (
            SELECT 1 FROM program_teachers pt
            WHERE pt.program_id = s."Programa"
            AND pt.teacher_unique_id = ' || quote_literal(filter_teacher) || ')';
    END IF;
    IF filter_sponsor IS NOT NULL THEN
        where_clause := where_clause || ' AND EXISTS (
            SELECT 1 FROM program_patrocinadores pp
            WHERE pp.program_id = s."Programa"
            AND pp.sponsor_id = ' || quote_literal(filter_sponsor) || ')';
    END IF;

    EXECUTE 'SELECT COUNT(*) FROM "Sociocultural Profile" sp
             INNER JOIN "Students" s ON sp.student = s."unique id" ' || where_clause INTO total_valido;

    RETURN QUERY EXECUTE
        'SELECT
            INITCAP(LOWER(TRIM(sp."Área de risco"))) as categoria,
            COUNT(*) as quantidade,
            ROUND((COUNT(*) * 100.0 / NULLIF(' || total_valido || ', 0)))::integer as percentual
        FROM "Sociocultural Profile" sp
        INNER JOIN "Students" s ON sp.student = s."unique id" ' || where_clause || '
        GROUP BY LOWER(TRIM(sp."Área de risco"))
        HAVING ROUND((COUNT(*) * 100.0 / NULLIF(' || total_valido || ', 0))) >= 5
        ORDER BY COUNT(*) DESC';
END;
$$;


ALTER FUNCTION "public"."get_stats_area_risco"("filter_instrument" "text", "filter_gender" "text", "filter_ethnicity" "text", "filter_age_range" "text", "filter_date_start" "text", "filter_date_end" "text", "filter_status" "text", "filter_classes" "text", "filter_programa" "text", "filter_teacher" "text", "filter_sponsor" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."get_stats_cursando"() RETURNS TABLE("categoria" "text", "quantidade" bigint, "percentual" numeric)
    LANGUAGE "plpgsql"
    AS $$
DECLARE
    total_valido bigint;
BEGIN
    SELECT COUNT(*) INTO total_valido 
    FROM "Sociocultural Profile" 
    WHERE cursando IS NOT NULL AND cursando != '';
    
    RETURN QUERY
    SELECT 
        cursando as categoria,
        COUNT(*) as quantidade,
        ROUND((COUNT(*) * 100.0 / NULLIF(total_valido, 0)), 2) as percentual
    FROM "Sociocultural Profile"
    WHERE cursando IS NOT NULL AND cursando != ''
    GROUP BY cursando
    ORDER BY COUNT(*) DESC;
END;
$$;


ALTER FUNCTION "public"."get_stats_cursando"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."get_stats_cursando"("filter_instrument" "text" DEFAULT NULL::"text", "filter_gender" "text" DEFAULT NULL::"text", "filter_ethnicity" "text" DEFAULT NULL::"text", "filter_age_range" "text" DEFAULT NULL::"text", "filter_date_start" "text" DEFAULT NULL::"text", "filter_date_end" "text" DEFAULT NULL::"text", "filter_status" "text" DEFAULT NULL::"text", "filter_classes" "text" DEFAULT NULL::"text", "filter_programa" "text" DEFAULT NULL::"text", "filter_teacher" "text" DEFAULT NULL::"text", "filter_sponsor" "text" DEFAULT NULL::"text") RETURNS TABLE("categoria" "text", "quantidade" bigint, "percentual" integer)
    LANGUAGE "plpgsql"
    AS $$
DECLARE
    total_valido bigint;
    where_clause text := 'WHERE sp.cursando IS NOT NULL AND sp.cursando != ''''';
BEGIN
    IF filter_instrument IS NOT NULL THEN
        where_clause := where_clause || ' AND s."Instrument_Enroll_Form" = ' || quote_literal(filter_instrument);
    END IF;
    IF filter_gender IS NOT NULL THEN
        where_clause := where_clause || ' AND s."Gender" = ' || quote_literal(filter_gender);
    END IF;
    IF filter_ethnicity IS NOT NULL THEN
        where_clause := where_clause || ' AND s."Ethnicity" = ' || quote_literal(filter_ethnicity);
    END IF;
    IF filter_age_range IS NOT NULL THEN
        CASE filter_age_range
            WHEN '0-6' THEN where_clause := where_clause || ' AND s."Age_Number" BETWEEN 0 AND 6';
            WHEN '7-12' THEN where_clause := where_clause || ' AND s."Age_Number" BETWEEN 7 AND 12';
            WHEN '13-17' THEN where_clause := where_clause || ' AND s."Age_Number" BETWEEN 13 AND 17';
            WHEN '18-29' THEN where_clause := where_clause || ' AND s."Age_Number" BETWEEN 18 AND 29';
            WHEN '30-59' THEN where_clause := where_clause || ' AND s."Age_Number" BETWEEN 30 AND 59';
            WHEN '60+' THEN where_clause := where_clause || ' AND s."Age_Number" >= 60';
        END CASE;
    END IF;
    IF filter_date_start IS NOT NULL THEN
        where_clause := where_clause || ' AND s."Creation Date"::date >= ' || quote_literal(filter_date_start);
    END IF;
    IF filter_date_end IS NOT NULL THEN
        where_clause := where_clause || ' AND s."Creation Date"::date <= ' || quote_literal(filter_date_end);
    END IF;
    IF filter_status IS NOT NULL THEN
        where_clause := where_clause || ' AND s."Status" = ' || quote_literal(filter_status);
    END IF;
    IF filter_classes IS NOT NULL THEN
        where_clause := where_clause || ' AND s."Classes" = ' || quote_literal(filter_classes);
    END IF;
    IF filter_programa IS NOT NULL THEN
        where_clause := where_clause || ' AND s."Programa" = ' || quote_literal(filter_programa);
    END IF;
    IF filter_teacher IS NOT NULL THEN
        where_clause := where_clause || ' AND EXISTS (
            SELECT 1 FROM program_teachers pt
            WHERE pt.program_id = s."Programa"
            AND pt.teacher_unique_id = ' || quote_literal(filter_teacher) || ')';
    END IF;
    IF filter_sponsor IS NOT NULL THEN
        where_clause := where_clause || ' AND EXISTS (
            SELECT 1 FROM program_patrocinadores pp
            WHERE pp.program_id = s."Programa"
            AND pp.sponsor_id = ' || quote_literal(filter_sponsor) || ')';
    END IF;

    EXECUTE 'SELECT COUNT(*) FROM "Sociocultural Profile" sp
             INNER JOIN "Students" s ON sp.student = s."unique id" ' || where_clause INTO total_valido;

    RETURN QUERY EXECUTE
        'SELECT
            INITCAP(LOWER(TRIM(sp.cursando))) as categoria,
            COUNT(*) as quantidade,
            ROUND((COUNT(*) * 100.0 / NULLIF(' || total_valido || ', 0)))::integer as percentual
        FROM "Sociocultural Profile" sp
        INNER JOIN "Students" s ON sp.student = s."unique id" ' || where_clause || '
        GROUP BY LOWER(TRIM(sp.cursando))
        HAVING ROUND((COUNT(*) * 100.0 / NULLIF(' || total_valido || ', 0))) >= 5
        ORDER BY COUNT(*) DESC';
END;
$$;


ALTER FUNCTION "public"."get_stats_cursando"("filter_instrument" "text", "filter_gender" "text", "filter_ethnicity" "text", "filter_age_range" "text", "filter_date_start" "text", "filter_date_end" "text", "filter_status" "text", "filter_classes" "text", "filter_programa" "text", "filter_teacher" "text", "filter_sponsor" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."get_stats_escolaridade_mae"() RETURNS TABLE("categoria" "text", "quantidade" bigint, "percentual" numeric)
    LANGUAGE "plpgsql"
    AS $$
DECLARE
    total_valido bigint;
BEGIN
    SELECT COUNT(*) INTO total_valido 
    FROM "Sociocultural Profile" 
    WHERE "escolaridade mãe" IS NOT NULL AND "escolaridade mãe" != '';
    
    RETURN QUERY
    SELECT 
        "escolaridade mãe" as categoria,
        COUNT(*) as quantidade,
        ROUND((COUNT(*) * 100.0 / NULLIF(total_valido, 0)), 2) as percentual
    FROM "Sociocultural Profile"
    WHERE "escolaridade mãe" IS NOT NULL AND "escolaridade mãe" != ''
    GROUP BY "escolaridade mãe"
    ORDER BY COUNT(*) DESC;
END;
$$;


ALTER FUNCTION "public"."get_stats_escolaridade_mae"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."get_stats_escolaridade_mae"("filter_instrument" "text" DEFAULT NULL::"text", "filter_gender" "text" DEFAULT NULL::"text", "filter_ethnicity" "text" DEFAULT NULL::"text", "filter_age_range" "text" DEFAULT NULL::"text", "filter_date_start" "text" DEFAULT NULL::"text", "filter_date_end" "text" DEFAULT NULL::"text", "filter_status" "text" DEFAULT NULL::"text", "filter_classes" "text" DEFAULT NULL::"text", "filter_programa" "text" DEFAULT NULL::"text", "filter_teacher" "text" DEFAULT NULL::"text", "filter_sponsor" "text" DEFAULT NULL::"text") RETURNS TABLE("categoria" "text", "quantidade" bigint, "percentual" integer)
    LANGUAGE "plpgsql"
    AS $$
DECLARE
    total_valido bigint;
    where_clause text := 'WHERE sp."escolaridade mãe" IS NOT NULL AND sp."escolaridade mãe" != ''''';
BEGIN
    IF filter_instrument IS NOT NULL THEN
        where_clause := where_clause || ' AND s."Instrument_Enroll_Form" = ' || quote_literal(filter_instrument);
    END IF;
    IF filter_gender IS NOT NULL THEN
        where_clause := where_clause || ' AND s."Gender" = ' || quote_literal(filter_gender);
    END IF;
    IF filter_ethnicity IS NOT NULL THEN
        where_clause := where_clause || ' AND s."Ethnicity" = ' || quote_literal(filter_ethnicity);
    END IF;
    IF filter_age_range IS NOT NULL THEN
        CASE filter_age_range
            WHEN '0-6' THEN where_clause := where_clause || ' AND s."Age_Number" BETWEEN 0 AND 6';
            WHEN '7-12' THEN where_clause := where_clause || ' AND s."Age_Number" BETWEEN 7 AND 12';
            WHEN '13-17' THEN where_clause := where_clause || ' AND s."Age_Number" BETWEEN 13 AND 17';
            WHEN '18-29' THEN where_clause := where_clause || ' AND s."Age_Number" BETWEEN 18 AND 29';
            WHEN '30-59' THEN where_clause := where_clause || ' AND s."Age_Number" BETWEEN 30 AND 59';
            WHEN '60+' THEN where_clause := where_clause || ' AND s."Age_Number" >= 60';
        END CASE;
    END IF;
    IF filter_date_start IS NOT NULL THEN
        where_clause := where_clause || ' AND s."Creation Date"::date >= ' || quote_literal(filter_date_start);
    END IF;
    IF filter_date_end IS NOT NULL THEN
        where_clause := where_clause || ' AND s."Creation Date"::date <= ' || quote_literal(filter_date_end);
    END IF;
    IF filter_status IS NOT NULL THEN
        where_clause := where_clause || ' AND s."Status" = ' || quote_literal(filter_status);
    END IF;
    IF filter_classes IS NOT NULL THEN
        where_clause := where_clause || ' AND s."Classes" = ' || quote_literal(filter_classes);
    END IF;
    IF filter_programa IS NOT NULL THEN
        where_clause := where_clause || ' AND s."Programa" = ' || quote_literal(filter_programa);
    END IF;
    IF filter_teacher IS NOT NULL THEN
        where_clause := where_clause || ' AND EXISTS (
            SELECT 1 FROM program_teachers pt
            WHERE pt.program_id = s."Programa"
            AND pt.teacher_unique_id = ' || quote_literal(filter_teacher) || ')';
    END IF;
    IF filter_sponsor IS NOT NULL THEN
        where_clause := where_clause || ' AND EXISTS (
            SELECT 1 FROM program_patrocinadores pp
            WHERE pp.program_id = s."Programa"
            AND pp.sponsor_id = ' || quote_literal(filter_sponsor) || ')';
    END IF;

    EXECUTE 'SELECT COUNT(*) FROM "Sociocultural Profile" sp
             INNER JOIN "Students" s ON sp.student = s."unique id" ' || where_clause INTO total_valido;

    RETURN QUERY EXECUTE
        'SELECT
            INITCAP(LOWER(TRIM(sp."escolaridade mãe"))) as categoria,
            COUNT(*) as quantidade,
            ROUND((COUNT(*) * 100.0 / NULLIF(' || total_valido || ', 0)))::integer as percentual
        FROM "Sociocultural Profile" sp
        INNER JOIN "Students" s ON sp.student = s."unique id" ' || where_clause || '
        GROUP BY LOWER(TRIM(sp."escolaridade mãe"))
        HAVING ROUND((COUNT(*) * 100.0 / NULLIF(' || total_valido || ', 0))) >= 5
        ORDER BY COUNT(*) DESC';
END;
$$;


ALTER FUNCTION "public"."get_stats_escolaridade_mae"("filter_instrument" "text", "filter_gender" "text", "filter_ethnicity" "text", "filter_age_range" "text", "filter_date_start" "text", "filter_date_end" "text", "filter_status" "text", "filter_classes" "text", "filter_programa" "text", "filter_teacher" "text", "filter_sponsor" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."get_stats_escolaridade_pai"() RETURNS TABLE("categoria" "text", "quantidade" bigint, "percentual" numeric)
    LANGUAGE "plpgsql"
    AS $$
DECLARE
    total_valido bigint;
BEGIN
    SELECT COUNT(*) INTO total_valido 
    FROM "Sociocultural Profile" 
    WHERE "escolaridade pai" IS NOT NULL AND "escolaridade pai" != '';
    
    RETURN QUERY
    SELECT 
        "escolaridade pai" as categoria,
        COUNT(*) as quantidade,
        ROUND((COUNT(*) * 100.0 / NULLIF(total_valido, 0)), 2) as percentual
    FROM "Sociocultural Profile"
    WHERE "escolaridade pai" IS NOT NULL AND "escolaridade pai" != ''
    GROUP BY "escolaridade pai"
    ORDER BY COUNT(*) DESC;
END;
$$;


ALTER FUNCTION "public"."get_stats_escolaridade_pai"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."get_stats_escolaridade_pai"("filter_instrument" "text" DEFAULT NULL::"text", "filter_gender" "text" DEFAULT NULL::"text", "filter_ethnicity" "text" DEFAULT NULL::"text", "filter_age_range" "text" DEFAULT NULL::"text", "filter_date_start" "text" DEFAULT NULL::"text", "filter_date_end" "text" DEFAULT NULL::"text", "filter_status" "text" DEFAULT NULL::"text", "filter_classes" "text" DEFAULT NULL::"text", "filter_programa" "text" DEFAULT NULL::"text", "filter_teacher" "text" DEFAULT NULL::"text", "filter_sponsor" "text" DEFAULT NULL::"text") RETURNS TABLE("categoria" "text", "quantidade" bigint, "percentual" integer)
    LANGUAGE "plpgsql"
    AS $$
DECLARE
    total_valido bigint;
    where_clause text := 'WHERE sp."escolaridade pai" IS NOT NULL AND sp."escolaridade pai" != ''''';
BEGIN
    IF filter_instrument IS NOT NULL THEN
        where_clause := where_clause || ' AND s."Instrument_Enroll_Form" = ' || quote_literal(filter_instrument);
    END IF;
    IF filter_gender IS NOT NULL THEN
        where_clause := where_clause || ' AND s."Gender" = ' || quote_literal(filter_gender);
    END IF;
    IF filter_ethnicity IS NOT NULL THEN
        where_clause := where_clause || ' AND s."Ethnicity" = ' || quote_literal(filter_ethnicity);
    END IF;
    IF filter_age_range IS NOT NULL THEN
        CASE filter_age_range
            WHEN '0-6' THEN where_clause := where_clause || ' AND s."Age_Number" BETWEEN 0 AND 6';
            WHEN '7-12' THEN where_clause := where_clause || ' AND s."Age_Number" BETWEEN 7 AND 12';
            WHEN '13-17' THEN where_clause := where_clause || ' AND s."Age_Number" BETWEEN 13 AND 17';
            WHEN '18-29' THEN where_clause := where_clause || ' AND s."Age_Number" BETWEEN 18 AND 29';
            WHEN '30-59' THEN where_clause := where_clause || ' AND s."Age_Number" BETWEEN 30 AND 59';
            WHEN '60+' THEN where_clause := where_clause || ' AND s."Age_Number" >= 60';
        END CASE;
    END IF;
    IF filter_date_start IS NOT NULL THEN
        where_clause := where_clause || ' AND s."Creation Date"::date >= ' || quote_literal(filter_date_start);
    END IF;
    IF filter_date_end IS NOT NULL THEN
        where_clause := where_clause || ' AND s."Creation Date"::date <= ' || quote_literal(filter_date_end);
    END IF;
    IF filter_status IS NOT NULL THEN
        where_clause := where_clause || ' AND s."Status" = ' || quote_literal(filter_status);
    END IF;
    IF filter_classes IS NOT NULL THEN
        where_clause := where_clause || ' AND s."Classes" = ' || quote_literal(filter_classes);
    END IF;
    IF filter_programa IS NOT NULL THEN
        where_clause := where_clause || ' AND s."Programa" = ' || quote_literal(filter_programa);
    END IF;
    IF filter_teacher IS NOT NULL THEN
        where_clause := where_clause || ' AND EXISTS (
            SELECT 1 FROM program_teachers pt
            WHERE pt.program_id = s."Programa"
            AND pt.teacher_unique_id = ' || quote_literal(filter_teacher) || ')';
    END IF;
    IF filter_sponsor IS NOT NULL THEN
        where_clause := where_clause || ' AND EXISTS (
            SELECT 1 FROM program_patrocinadores pp
            WHERE pp.program_id = s."Programa"
            AND pp.sponsor_id = ' || quote_literal(filter_sponsor) || ')';
    END IF;

    EXECUTE 'SELECT COUNT(*) FROM "Sociocultural Profile" sp
             INNER JOIN "Students" s ON sp.student = s."unique id" ' || where_clause INTO total_valido;

    RETURN QUERY EXECUTE
        'SELECT
            INITCAP(LOWER(TRIM(sp."escolaridade pai"))) as categoria,
            COUNT(*) as quantidade,
            ROUND((COUNT(*) * 100.0 / NULLIF(' || total_valido || ', 0)))::integer as percentual
        FROM "Sociocultural Profile" sp
        INNER JOIN "Students" s ON sp.student = s."unique id" ' || where_clause || '
        GROUP BY LOWER(TRIM(sp."escolaridade pai"))
        HAVING ROUND((COUNT(*) * 100.0 / NULLIF(' || total_valido || ', 0))) >= 5
        ORDER BY COUNT(*) DESC';
END;
$$;


ALTER FUNCTION "public"."get_stats_escolaridade_pai"("filter_instrument" "text", "filter_gender" "text", "filter_ethnicity" "text", "filter_age_range" "text", "filter_date_start" "text", "filter_date_end" "text", "filter_status" "text", "filter_classes" "text", "filter_programa" "text", "filter_teacher" "text", "filter_sponsor" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."get_stats_etnia"("filter_programa" "text" DEFAULT NULL::"text", "filter_status" "text" DEFAULT NULL::"text", "filter_sponsor" "text" DEFAULT NULL::"text", "filter_etnia" "text" DEFAULT NULL::"text", "filter_instrumento" "text" DEFAULT NULL::"text", "filter_professor" "text" DEFAULT NULL::"text", "filter_turma" "text" DEFAULT NULL::"text", "filter_genero" "text" DEFAULT NULL::"text", "filter_faixa_etaria" "text" DEFAULT NULL::"text") RETURNS TABLE("categoria" "text", "quantidade" bigint, "percentual" integer)
    LANGUAGE "plpgsql" STABLE
    AS $$
DECLARE
  total_count bigint;
  v_age_min   integer := NULL;
  v_age_max   integer := NULL;
BEGIN
  -- Traduz faixa etaria para intervalo numerico
  CASE filter_faixa_etaria
    WHEN '0-6'   THEN v_age_min := 0;  v_age_max := 6;
    WHEN '7-12'  THEN v_age_min := 7;  v_age_max := 12;
    WHEN '13-17' THEN v_age_min := 13; v_age_max := 17;
    WHEN '18-29' THEN v_age_min := 18; v_age_max := 29;
    WHEN '30-59' THEN v_age_min := 30; v_age_max := 59;
    WHEN '59+'   THEN v_age_min := 59; v_age_max := NULL;
    WHEN '60+'   THEN v_age_min := 60; v_age_max := NULL;
    ELSE NULL;
  END CASE;

  SELECT COUNT(*) INTO total_count
  FROM "Students" s
  WHERE ("Ethnicity" IS NOT NULL AND TRIM("Ethnicity") <> '')
    AND (filter_status      IS NULL OR s."Status"     = filter_status)
    AND (filter_programa    IS NULL OR s."Programa"   = filter_programa)
    AND (filter_genero      IS NULL OR LOWER(TRIM(s."Gender")) = LOWER(TRIM(filter_genero)))
    AND (v_age_min          IS NULL OR s."Age_Number" >= v_age_min)
    AND (v_age_max          IS NULL OR s."Age_Number" <= v_age_max)
    AND (filter_sponsor     IS NULL OR s."Programa" IN (
          SELECT pp.program_id FROM program_patrocinadores pp WHERE pp.sponsor_id = filter_sponsor
        ))
    AND (
      (filter_instrumento IS NULL AND filter_professor IS NULL AND filter_turma IS NULL)
      OR EXISTS (
        SELECT 1
        FROM attendance a
        JOIN schedule sc ON sc.unique_id = a.schedule_id
        JOIN class c     ON c.unique_id  = sc.class_id
        WHERE a.student_id = s."unique id"
          AND (filter_instrumento IS NULL OR c.instrument_os ILIKE ('%' || filter_instrumento || '%'))
          AND (filter_professor   IS NULL OR sc.teacher_id = filter_professor)
          AND (filter_turma       IS NULL OR c.unique_id   = filter_turma)
      )
    );

  RETURN QUERY
  SELECT
    INITCAP(LOWER(TRIM(SPLIT_PART("Ethnicity", ',', 1)))) AS categoria,
    COUNT(*)::bigint AS quantidade,
    CASE WHEN total_count > 0
         THEN ROUND(COUNT(*) * 100.0 / total_count)::integer
         ELSE 0
    END AS percentual
  FROM "Students" s
  WHERE ("Ethnicity" IS NOT NULL AND TRIM("Ethnicity") <> '')
    AND (filter_status      IS NULL OR s."Status"     = filter_status)
    AND (filter_programa    IS NULL OR s."Programa"   = filter_programa)
    AND (filter_etnia       IS NULL OR INITCAP(LOWER(TRIM(SPLIT_PART("Ethnicity", ',', 1)))) = INITCAP(LOWER(TRIM(filter_etnia))))
    AND (filter_genero      IS NULL OR LOWER(TRIM(s."Gender")) = LOWER(TRIM(filter_genero)))
    AND (v_age_min          IS NULL OR s."Age_Number" >= v_age_min)
    AND (v_age_max          IS NULL OR s."Age_Number" <= v_age_max)
    AND (filter_sponsor     IS NULL OR s."Programa" IN (
          SELECT pp.program_id FROM program_patrocinadores pp WHERE pp.sponsor_id = filter_sponsor
        ))
    AND (
      (filter_instrumento IS NULL AND filter_professor IS NULL AND filter_turma IS NULL)
      OR EXISTS (
        SELECT 1
        FROM attendance a
        JOIN schedule sc ON sc.unique_id = a.schedule_id
        JOIN class c     ON c.unique_id  = sc.class_id
        WHERE a.student_id = s."unique id"
          AND (filter_instrumento IS NULL OR c.instrument_os ILIKE ('%' || filter_instrumento || '%'))
          AND (filter_professor   IS NULL OR sc.teacher_id = filter_professor)
          AND (filter_turma       IS NULL OR c.unique_id   = filter_turma)
      )
    )
  GROUP BY 1
  ORDER BY 2 DESC;
END;
$$;


ALTER FUNCTION "public"."get_stats_etnia"("filter_programa" "text", "filter_status" "text", "filter_sponsor" "text", "filter_etnia" "text", "filter_instrumento" "text", "filter_professor" "text", "filter_turma" "text", "filter_genero" "text", "filter_faixa_etaria" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."get_stats_mora_comunidade"() RETURNS TABLE("categoria" "text", "quantidade" bigint, "percentual" numeric)
    LANGUAGE "plpgsql"
    AS $$
DECLARE
    total_valido bigint;
BEGIN
    SELECT COUNT(*) INTO total_valido 
    FROM "Sociocultural Profile" 
    WHERE "comunidade?" IS NOT NULL;
    
    RETURN QUERY
    SELECT 
        CASE 
            WHEN "comunidade?" = 'true' THEN 'Sim'
            WHEN "comunidade?" = 'false' THEN 'Não'
            ELSE 'Não informado'
        END as categoria,
        COUNT(*) as quantidade,
        ROUND((COUNT(*) * 100.0 / NULLIF(total_valido, 0)), 2) as percentual
    FROM "Sociocultural Profile"
    WHERE "comunidade?" IS NOT NULL
    GROUP BY "comunidade?"
    ORDER BY COUNT(*) DESC;
END;
$$;


ALTER FUNCTION "public"."get_stats_mora_comunidade"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."get_stats_mora_comunidade"("filter_instrument" "text" DEFAULT NULL::"text", "filter_gender" "text" DEFAULT NULL::"text", "filter_ethnicity" "text" DEFAULT NULL::"text", "filter_age_range" "text" DEFAULT NULL::"text", "filter_date_start" "text" DEFAULT NULL::"text", "filter_date_end" "text" DEFAULT NULL::"text", "filter_status" "text" DEFAULT NULL::"text", "filter_classes" "text" DEFAULT NULL::"text", "filter_programa" "text" DEFAULT NULL::"text", "filter_teacher" "text" DEFAULT NULL::"text", "filter_sponsor" "text" DEFAULT NULL::"text") RETURNS TABLE("categoria" "text", "quantidade" bigint, "percentual" integer)
    LANGUAGE "plpgsql"
    AS $$
DECLARE
    total_valido bigint;
    where_clause text := 'WHERE sp."comunidade?" IS NOT NULL';
BEGIN
    IF filter_instrument IS NOT NULL THEN
        where_clause := where_clause || ' AND s."Instrument_Enroll_Form" = ' || quote_literal(filter_instrument);
    END IF;
    IF filter_gender IS NOT NULL THEN
        where_clause := where_clause || ' AND s."Gender" = ' || quote_literal(filter_gender);
    END IF;
    IF filter_ethnicity IS NOT NULL THEN
        where_clause := where_clause || ' AND s."Ethnicity" = ' || quote_literal(filter_ethnicity);
    END IF;
    IF filter_age_range IS NOT NULL THEN
        CASE filter_age_range
            WHEN '0-6' THEN where_clause := where_clause || ' AND s."Age_Number" BETWEEN 0 AND 6';
            WHEN '7-12' THEN where_clause := where_clause || ' AND s."Age_Number" BETWEEN 7 AND 12';
            WHEN '13-17' THEN where_clause := where_clause || ' AND s."Age_Number" BETWEEN 13 AND 17';
            WHEN '18-29' THEN where_clause := where_clause || ' AND s."Age_Number" BETWEEN 18 AND 29';
            WHEN '30-59' THEN where_clause := where_clause || ' AND s."Age_Number" BETWEEN 30 AND 59';
            WHEN '60+' THEN where_clause := where_clause || ' AND s."Age_Number" >= 60';
        END CASE;
    END IF;
    IF filter_date_start IS NOT NULL THEN
        where_clause := where_clause || ' AND s."Creation Date"::date >= ' || quote_literal(filter_date_start);
    END IF;
    IF filter_date_end IS NOT NULL THEN
        where_clause := where_clause || ' AND s."Creation Date"::date <= ' || quote_literal(filter_date_end);
    END IF;
    IF filter_status IS NOT NULL THEN
        where_clause := where_clause || ' AND s."Status" = ' || quote_literal(filter_status);
    END IF;
    IF filter_classes IS NOT NULL THEN
        where_clause := where_clause || ' AND s."Classes" = ' || quote_literal(filter_classes);
    END IF;
    IF filter_programa IS NOT NULL THEN
        where_clause := where_clause || ' AND s."Programa" = ' || quote_literal(filter_programa);
    END IF;
    -- Novo filtro por professor
    IF filter_teacher IS NOT NULL THEN
        where_clause := where_clause || ' AND EXISTS (
            SELECT 1 FROM program_teachers pt
            WHERE pt.program_id = s."Programa"
            AND pt.teacher_unique_id = ' || quote_literal(filter_teacher) || ')';
    END IF;
    -- Novo filtro por patrocinador
    IF filter_sponsor IS NOT NULL THEN
        where_clause := where_clause || ' AND EXISTS (
            SELECT 1 FROM program_patrocinadores pp
            WHERE pp.program_id = s."Programa"
            AND pp.sponsor_id = ' || quote_literal(filter_sponsor) || ')';
    END IF;

    EXECUTE 'SELECT COUNT(*) FROM "Sociocultural Profile" sp
             INNER JOIN "Students" s ON sp.student = s."unique id" ' || where_clause INTO total_valido;

    RETURN QUERY EXECUTE
        'SELECT
            INITCAP(CASE
                WHEN sp."comunidade?" = ''true'' THEN ''sim''
                WHEN sp."comunidade?" = ''false'' THEN ''não''
                ELSE ''não informado''
            END) as categoria,
            COUNT(*) as quantidade,
            ROUND((COUNT(*) * 100.0 / NULLIF(' || total_valido || ', 0)))::integer as percentual
        FROM "Sociocultural Profile" sp
        INNER JOIN "Students" s ON sp.student = s."unique id" ' || where_clause || '
        GROUP BY sp."comunidade?"
        HAVING ROUND((COUNT(*) * 100.0 / NULLIF(' || total_valido || ', 0))) >= 5
        ORDER BY COUNT(*) DESC';
END;
$$;


ALTER FUNCTION "public"."get_stats_mora_comunidade"("filter_instrument" "text", "filter_gender" "text", "filter_ethnicity" "text", "filter_age_range" "text", "filter_date_start" "text", "filter_date_end" "text", "filter_status" "text", "filter_classes" "text", "filter_programa" "text", "filter_teacher" "text", "filter_sponsor" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."get_stats_pavimentacao"() RETURNS TABLE("categoria" "text", "quantidade" bigint, "percentual" numeric)
    LANGUAGE "plpgsql"
    AS $$
DECLARE
    total_valido bigint;
BEGIN
    SELECT COUNT(*) INTO total_valido 
    FROM "Sociocultural Profile" 
    WHERE pavimentação IS NOT NULL AND pavimentação != '';
    
    RETURN QUERY
    SELECT 
        pavimentação as categoria,
        COUNT(*) as quantidade,
        ROUND((COUNT(*) * 100.0 / NULLIF(total_valido, 0)), 2) as percentual
    FROM "Sociocultural Profile"
    WHERE pavimentação IS NOT NULL AND pavimentação != ''
    GROUP BY pavimentação
    ORDER BY COUNT(*) DESC;
END;
$$;


ALTER FUNCTION "public"."get_stats_pavimentacao"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."get_stats_pavimentacao"("filter_instrument" "text" DEFAULT NULL::"text", "filter_gender" "text" DEFAULT NULL::"text", "filter_ethnicity" "text" DEFAULT NULL::"text", "filter_age_range" "text" DEFAULT NULL::"text", "filter_date_start" "text" DEFAULT NULL::"text", "filter_date_end" "text" DEFAULT NULL::"text", "filter_status" "text" DEFAULT NULL::"text", "filter_classes" "text" DEFAULT NULL::"text", "filter_programa" "text" DEFAULT NULL::"text", "filter_teacher" "text" DEFAULT NULL::"text", "filter_sponsor" "text" DEFAULT NULL::"text") RETURNS TABLE("categoria" "text", "quantidade" bigint, "percentual" integer)
    LANGUAGE "plpgsql"
    AS $$
DECLARE
    total_valido bigint;
    where_clause text := 'WHERE sp.pavimentação IS NOT NULL AND sp.pavimentação != ''''';
BEGIN
    IF filter_instrument IS NOT NULL THEN
        where_clause := where_clause || ' AND s."Instrument_Enroll_Form" = ' || quote_literal(filter_instrument);
    END IF;
    IF filter_gender IS NOT NULL THEN
        where_clause := where_clause || ' AND s."Gender" = ' || quote_literal(filter_gender);
    END IF;
    IF filter_ethnicity IS NOT NULL THEN
        where_clause := where_clause || ' AND s."Ethnicity" = ' || quote_literal(filter_ethnicity);
    END IF;
    IF filter_age_range IS NOT NULL THEN
        CASE filter_age_range
            WHEN '0-6' THEN where_clause := where_clause || ' AND s."Age_Number" BETWEEN 0 AND 6';
            WHEN '7-12' THEN where_clause := where_clause || ' AND s."Age_Number" BETWEEN 7 AND 12';
            WHEN '13-17' THEN where_clause := where_clause || ' AND s."Age_Number" BETWEEN 13 AND 17';
            WHEN '18-29' THEN where_clause := where_clause || ' AND s."Age_Number" BETWEEN 18 AND 29';
            WHEN '30-59' THEN where_clause := where_clause || ' AND s."Age_Number" BETWEEN 30 AND 59';
            WHEN '60+' THEN where_clause := where_clause || ' AND s."Age_Number" >= 60';
        END CASE;
    END IF;
    IF filter_date_start IS NOT NULL THEN
        where_clause := where_clause || ' AND s."Creation Date"::date >= ' || quote_literal(filter_date_start);
    END IF;
    IF filter_date_end IS NOT NULL THEN
        where_clause := where_clause || ' AND s."Creation Date"::date <= ' || quote_literal(filter_date_end);
    END IF;
    IF filter_status IS NOT NULL THEN
        where_clause := where_clause || ' AND s."Status" = ' || quote_literal(filter_status);
    END IF;
    IF filter_classes IS NOT NULL THEN
        where_clause := where_clause || ' AND s."Classes" = ' || quote_literal(filter_classes);
    END IF;
    IF filter_programa IS NOT NULL THEN
        where_clause := where_clause || ' AND s."Programa" = ' || quote_literal(filter_programa);
    END IF;
    IF filter_teacher IS NOT NULL THEN
        where_clause := where_clause || ' AND EXISTS (
            SELECT 1 FROM program_teachers pt
            WHERE pt.program_id = s."Programa"
            AND pt.teacher_unique_id = ' || quote_literal(filter_teacher) || ')';
    END IF;
    IF filter_sponsor IS NOT NULL THEN
        where_clause := where_clause || ' AND EXISTS (
            SELECT 1 FROM program_patrocinadores pp
            WHERE pp.program_id = s."Programa"
            AND pp.sponsor_id = ' || quote_literal(filter_sponsor) || ')';
    END IF;

    EXECUTE 'SELECT COUNT(*) FROM "Sociocultural Profile" sp
             INNER JOIN "Students" s ON sp.student = s."unique id" ' || where_clause INTO total_valido;

    RETURN QUERY EXECUTE
        'SELECT
            INITCAP(LOWER(TRIM(sp.pavimentação))) as categoria,
            COUNT(*) as quantidade,
            ROUND((COUNT(*) * 100.0 / NULLIF(' || total_valido || ', 0)))::integer as percentual
        FROM "Sociocultural Profile" sp
        INNER JOIN "Students" s ON sp.student = s."unique id" ' || where_clause || '
        GROUP BY LOWER(TRIM(sp.pavimentação))
        ORDER BY COUNT(*) DESC';
END;
$$;


ALTER FUNCTION "public"."get_stats_pavimentacao"("filter_instrument" "text", "filter_gender" "text", "filter_ethnicity" "text", "filter_age_range" "text", "filter_date_start" "text", "filter_date_end" "text", "filter_status" "text", "filter_classes" "text", "filter_programa" "text", "filter_teacher" "text", "filter_sponsor" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."get_stats_qtde_moradores"() RETURNS TABLE("categoria" "text", "quantidade" bigint, "percentual" numeric)
    LANGUAGE "plpgsql"
    AS $$
DECLARE
    total_valido bigint;
BEGIN
    SELECT COUNT(*) INTO total_valido 
    FROM "Sociocultural Profile" 
    WHERE "qtde de moradores" IS NOT NULL AND "qtde de moradores" != '';
    
    RETURN QUERY
    SELECT 
        "qtde de moradores" as categoria,
        COUNT(*) as quantidade,
        ROUND((COUNT(*) * 100.0 / NULLIF(total_valido, 0)), 2) as percentual
    FROM "Sociocultural Profile"
    WHERE "qtde de moradores" IS NOT NULL AND "qtde de moradores" != ''
    GROUP BY "qtde de moradores"
    ORDER BY COUNT(*) DESC;
END;
$$;


ALTER FUNCTION "public"."get_stats_qtde_moradores"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."get_stats_qtde_moradores"("filter_instrument" "text" DEFAULT NULL::"text", "filter_gender" "text" DEFAULT NULL::"text", "filter_ethnicity" "text" DEFAULT NULL::"text", "filter_age_range" "text" DEFAULT NULL::"text", "filter_date_start" "text" DEFAULT NULL::"text", "filter_date_end" "text" DEFAULT NULL::"text", "filter_status" "text" DEFAULT NULL::"text", "filter_classes" "text" DEFAULT NULL::"text", "filter_programa" "text" DEFAULT NULL::"text", "filter_teacher" "text" DEFAULT NULL::"text", "filter_sponsor" "text" DEFAULT NULL::"text") RETURNS TABLE("categoria" "text", "quantidade" bigint, "percentual" integer)
    LANGUAGE "plpgsql"
    AS $$
DECLARE
    total_valido bigint;
    where_clause text := 'WHERE sp."qtde de moradores" IS NOT NULL AND sp."qtde de moradores" != ''''';
BEGIN
    IF filter_instrument IS NOT NULL THEN
        where_clause := where_clause || ' AND s."Instrument_Enroll_Form" = ' || quote_literal(filter_instrument);
    END IF;
    IF filter_gender IS NOT NULL THEN
        where_clause := where_clause || ' AND s."Gender" = ' || quote_literal(filter_gender);
    END IF;
    IF filter_ethnicity IS NOT NULL THEN
        where_clause := where_clause || ' AND s."Ethnicity" = ' || quote_literal(filter_ethnicity);
    END IF;
    IF filter_age_range IS NOT NULL THEN
        CASE filter_age_range
            WHEN '0-6' THEN where_clause := where_clause || ' AND s."Age_Number" BETWEEN 0 AND 6';
            WHEN '7-12' THEN where_clause := where_clause || ' AND s."Age_Number" BETWEEN 7 AND 12';
            WHEN '13-17' THEN where_clause := where_clause || ' AND s."Age_Number" BETWEEN 13 AND 17';
            WHEN '18-29' THEN where_clause := where_clause || ' AND s."Age_Number" BETWEEN 18 AND 29';
            WHEN '30-59' THEN where_clause := where_clause || ' AND s."Age_Number" BETWEEN 30 AND 59';
            WHEN '60+' THEN where_clause := where_clause || ' AND s."Age_Number" >= 60';
        END CASE;
    END IF;
    IF filter_date_start IS NOT NULL THEN
        where_clause := where_clause || ' AND s."Creation Date"::date >= ' || quote_literal(filter_date_start);
    END IF;
    IF filter_date_end IS NOT NULL THEN
        where_clause := where_clause || ' AND s."Creation Date"::date <= ' || quote_literal(filter_date_end);
    END IF;
    IF filter_status IS NOT NULL THEN
        where_clause := where_clause || ' AND s."Status" = ' || quote_literal(filter_status);
    END IF;
    IF filter_classes IS NOT NULL THEN
        where_clause := where_clause || ' AND s."Classes" = ' || quote_literal(filter_classes);
    END IF;
    IF filter_programa IS NOT NULL THEN
        where_clause := where_clause || ' AND s."Programa" = ' || quote_literal(filter_programa);
    END IF;
    IF filter_teacher IS NOT NULL THEN
        where_clause := where_clause || ' AND EXISTS (
            SELECT 1 FROM program_teachers pt
            WHERE pt.program_id = s."Programa"
            AND pt.teacher_unique_id = ' || quote_literal(filter_teacher) || ')';
    END IF;
    IF filter_sponsor IS NOT NULL THEN
        where_clause := where_clause || ' AND EXISTS (
            SELECT 1 FROM program_patrocinadores pp
            WHERE pp.program_id = s."Programa"
            AND pp.sponsor_id = ' || quote_literal(filter_sponsor) || ')';
    END IF;

    EXECUTE 'SELECT COUNT(*) FROM "Sociocultural Profile" sp
             INNER JOIN "Students" s ON sp.student = s."unique id" ' || where_clause INTO total_valido;

    RETURN QUERY EXECUTE
        'SELECT
            INITCAP(LOWER(TRIM(sp."qtde de moradores"))) as categoria,
            COUNT(*) as quantidade,
            ROUND((COUNT(*) * 100.0 / NULLIF(' || total_valido || ', 0)))::integer as percentual
        FROM "Sociocultural Profile" sp
        INNER JOIN "Students" s ON sp.student = s."unique id" ' || where_clause || '
        GROUP BY LOWER(TRIM(sp."qtde de moradores"))
        HAVING ROUND((COUNT(*) * 100.0 / NULLIF(' || total_valido || ', 0))) >= 5
        ORDER BY COUNT(*) DESC';
END;
$$;


ALTER FUNCTION "public"."get_stats_qtde_moradores"("filter_instrument" "text", "filter_gender" "text", "filter_ethnicity" "text", "filter_age_range" "text", "filter_date_start" "text", "filter_date_end" "text", "filter_status" "text", "filter_classes" "text", "filter_programa" "text", "filter_teacher" "text", "filter_sponsor" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."get_stats_recebe_ibme"() RETURNS TABLE("categoria" "text", "quantidade" bigint, "percentual" numeric)
    LANGUAGE "plpgsql"
    AS $$
DECLARE
    total_valido bigint;
BEGIN
    SELECT COUNT(*) INTO total_valido 
    FROM "Sociocultural Profile" 
    WHERE "recebe do IBME" IS NOT NULL AND "recebe do IBME" != '';
    
    RETURN QUERY
    SELECT 
        "recebe do IBME" as categoria,
        COUNT(*) as quantidade,
        ROUND((COUNT(*) * 100.0 / NULLIF(total_valido, 0)), 2) as percentual
    FROM "Sociocultural Profile"
    WHERE "recebe do IBME" IS NOT NULL AND "recebe do IBME" != ''
    GROUP BY "recebe do IBME"
    ORDER BY COUNT(*) DESC;
END;
$$;


ALTER FUNCTION "public"."get_stats_recebe_ibme"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."get_stats_recebe_ibme"("filter_instrument" "text" DEFAULT NULL::"text", "filter_gender" "text" DEFAULT NULL::"text", "filter_ethnicity" "text" DEFAULT NULL::"text", "filter_age_range" "text" DEFAULT NULL::"text", "filter_date_start" "text" DEFAULT NULL::"text", "filter_date_end" "text" DEFAULT NULL::"text", "filter_status" "text" DEFAULT NULL::"text", "filter_classes" "text" DEFAULT NULL::"text", "filter_programa" "text" DEFAULT NULL::"text", "filter_teacher" "text" DEFAULT NULL::"text", "filter_sponsor" "text" DEFAULT NULL::"text") RETURNS TABLE("categoria" "text", "quantidade" bigint, "percentual" integer)
    LANGUAGE "plpgsql"
    AS $$
DECLARE
    total_valido bigint;
    where_clause text := 'WHERE sp."recebe do IBME" IS NOT NULL AND sp."recebe do IBME" != ''''';
BEGIN
    IF filter_instrument IS NOT NULL THEN
        where_clause := where_clause || ' AND s."Instrument_Enroll_Form" = ' || quote_literal(filter_instrument);
    END IF;
    IF filter_gender IS NOT NULL THEN
        where_clause := where_clause || ' AND s."Gender" = ' || quote_literal(filter_gender);
    END IF;
    IF filter_ethnicity IS NOT NULL THEN
        where_clause := where_clause || ' AND s."Ethnicity" = ' || quote_literal(filter_ethnicity);
    END IF;
    IF filter_age_range IS NOT NULL THEN
        CASE filter_age_range
            WHEN '0-6' THEN where_clause := where_clause || ' AND s."Age_Number" BETWEEN 0 AND 6';
            WHEN '7-12' THEN where_clause := where_clause || ' AND s."Age_Number" BETWEEN 7 AND 12';
            WHEN '13-17' THEN where_clause := where_clause || ' AND s."Age_Number" BETWEEN 13 AND 17';
            WHEN '18-29' THEN where_clause := where_clause || ' AND s."Age_Number" BETWEEN 18 AND 29';
            WHEN '30-59' THEN where_clause := where_clause || ' AND s."Age_Number" BETWEEN 30 AND 59';
            WHEN '60+' THEN where_clause := where_clause || ' AND s."Age_Number" >= 60';
        END CASE;
    END IF;
    IF filter_date_start IS NOT NULL THEN
        where_clause := where_clause || ' AND s."Creation Date"::date >= ' || quote_literal(filter_date_start);
    END IF;
    IF filter_date_end IS NOT NULL THEN
        where_clause := where_clause || ' AND s."Creation Date"::date <= ' || quote_literal(filter_date_end);
    END IF;
    IF filter_status IS NOT NULL THEN
        where_clause := where_clause || ' AND s."Status" = ' || quote_literal(filter_status);
    END IF;
    IF filter_classes IS NOT NULL THEN
        where_clause := where_clause || ' AND s."Classes" = ' || quote_literal(filter_classes);
    END IF;
    IF filter_programa IS NOT NULL THEN
        where_clause := where_clause || ' AND s."Programa" = ' || quote_literal(filter_programa);
    END IF;
    IF filter_teacher IS NOT NULL THEN
        where_clause := where_clause || ' AND EXISTS (
            SELECT 1 FROM program_teachers pt
            WHERE pt.program_id = s."Programa"
            AND pt.teacher_unique_id = ' || quote_literal(filter_teacher) || ')';
    END IF;
    IF filter_sponsor IS NOT NULL THEN
        where_clause := where_clause || ' AND EXISTS (
            SELECT 1 FROM program_patrocinadores pp
            WHERE pp.program_id = s."Programa"
            AND pp.sponsor_id = ' || quote_literal(filter_sponsor) || ')';
    END IF;

    EXECUTE 'SELECT COUNT(*) FROM "Sociocultural Profile" sp
             INNER JOIN "Students" s ON sp.student = s."unique id" ' || where_clause INTO total_valido;

    RETURN QUERY EXECUTE
        'SELECT
            INITCAP(LOWER(TRIM(sp."recebe do IBME"))) as categoria,
            COUNT(*) as quantidade,
            ROUND((COUNT(*) * 100.0 / NULLIF(' || total_valido || ', 0)))::integer as percentual
        FROM "Sociocultural Profile" sp
        INNER JOIN "Students" s ON sp.student = s."unique id" ' || where_clause || '
        GROUP BY LOWER(TRIM(sp."recebe do IBME"))
        HAVING ROUND((COUNT(*) * 100.0 / NULLIF(' || total_valido || ', 0))) >= 5
        ORDER BY COUNT(*) DESC';
END;
$$;


ALTER FUNCTION "public"."get_stats_recebe_ibme"("filter_instrument" "text", "filter_gender" "text", "filter_ethnicity" "text", "filter_age_range" "text", "filter_date_start" "text", "filter_date_end" "text", "filter_status" "text", "filter_classes" "text", "filter_programa" "text", "filter_teacher" "text", "filter_sponsor" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."get_stats_regiao"() RETURNS TABLE("categoria" "text", "quantidade" bigint, "percentual" numeric)
    LANGUAGE "plpgsql"
    AS $$
DECLARE
    total_valido bigint;
BEGIN
    SELECT COUNT(*) INTO total_valido 
    FROM "Sociocultural Profile" 
    WHERE "Região" IS NOT NULL AND "Região" != '';
    
    RETURN QUERY
    SELECT 
        "Região" as categoria,
        COUNT(*) as quantidade,
        ROUND((COUNT(*) * 100.0 / NULLIF(total_valido, 0)), 2) as percentual
    FROM "Sociocultural Profile"
    WHERE "Região" IS NOT NULL AND "Região" != ''
    GROUP BY "Região"
    ORDER BY COUNT(*) DESC;
END;
$$;


ALTER FUNCTION "public"."get_stats_regiao"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."get_stats_regiao"("filter_instrument" "text" DEFAULT NULL::"text", "filter_gender" "text" DEFAULT NULL::"text", "filter_ethnicity" "text" DEFAULT NULL::"text", "filter_age_range" "text" DEFAULT NULL::"text", "filter_date_start" "text" DEFAULT NULL::"text", "filter_date_end" "text" DEFAULT NULL::"text", "filter_status" "text" DEFAULT NULL::"text", "filter_classes" "text" DEFAULT NULL::"text", "filter_programa" "text" DEFAULT NULL::"text", "filter_teacher" "text" DEFAULT NULL::"text", "filter_sponsor" "text" DEFAULT NULL::"text") RETURNS TABLE("categoria" "text", "quantidade" bigint, "percentual" integer)
    LANGUAGE "plpgsql"
    AS $$
DECLARE
    total_valido bigint;
    where_clause text := 'WHERE sp."Região" IS NOT NULL AND sp."Região" != ''''';
BEGIN
    IF filter_instrument IS NOT NULL THEN
        where_clause := where_clause || ' AND s."Instrument_Enroll_Form" = ' || quote_literal(filter_instrument);
    END IF;
    IF filter_gender IS NOT NULL THEN
        where_clause := where_clause || ' AND s."Gender" = ' || quote_literal(filter_gender);
    END IF;
    IF filter_ethnicity IS NOT NULL THEN
        where_clause := where_clause || ' AND s."Ethnicity" = ' || quote_literal(filter_ethnicity);
    END IF;
    IF filter_age_range IS NOT NULL THEN
        CASE filter_age_range
            WHEN '0-6' THEN where_clause := where_clause || ' AND s."Age_Number" BETWEEN 0 AND 6';
            WHEN '7-12' THEN where_clause := where_clause || ' AND s."Age_Number" BETWEEN 7 AND 12';
            WHEN '13-17' THEN where_clause := where_clause || ' AND s."Age_Number" BETWEEN 13 AND 17';
            WHEN '18-29' THEN where_clause := where_clause || ' AND s."Age_Number" BETWEEN 18 AND 29';
            WHEN '30-59' THEN where_clause := where_clause || ' AND s."Age_Number" BETWEEN 30 AND 59';
            WHEN '60+' THEN where_clause := where_clause || ' AND s."Age_Number" >= 60';
        END CASE;
    END IF;
    IF filter_date_start IS NOT NULL THEN
        where_clause := where_clause || ' AND s."Creation Date"::date >= ' || quote_literal(filter_date_start);
    END IF;
    IF filter_date_end IS NOT NULL THEN
        where_clause := where_clause || ' AND s."Creation Date"::date <= ' || quote_literal(filter_date_end);
    END IF;
    IF filter_status IS NOT NULL THEN
        where_clause := where_clause || ' AND s."Status" = ' || quote_literal(filter_status);
    END IF;
    IF filter_classes IS NOT NULL THEN
        where_clause := where_clause || ' AND s."Classes" = ' || quote_literal(filter_classes);
    END IF;
    IF filter_programa IS NOT NULL THEN
        where_clause := where_clause || ' AND s."Programa" = ' || quote_literal(filter_programa);
    END IF;
    IF filter_teacher IS NOT NULL THEN
        where_clause := where_clause || ' AND EXISTS (
            SELECT 1 FROM program_teachers pt
            WHERE pt.program_id = s."Programa"
            AND pt.teacher_unique_id = ' || quote_literal(filter_teacher) || ')';
    END IF;
    IF filter_sponsor IS NOT NULL THEN
        where_clause := where_clause || ' AND EXISTS (
            SELECT 1 FROM program_patrocinadores pp
            WHERE pp.program_id = s."Programa"
            AND pp.sponsor_id = ' || quote_literal(filter_sponsor) || ')';
    END IF;

    EXECUTE 'SELECT COUNT(*) FROM "Sociocultural Profile" sp
             INNER JOIN "Students" s ON sp.student = s."unique id" ' || where_clause INTO total_valido;

    RETURN QUERY EXECUTE
        'SELECT
            INITCAP(LOWER(TRIM(sp."Região"))) as categoria,
            COUNT(*) as quantidade,
            ROUND((COUNT(*) * 100.0 / NULLIF(' || total_valido || ', 0)))::integer as percentual
        FROM "Sociocultural Profile" sp
        INNER JOIN "Students" s ON sp.student = s."unique id" ' || where_clause || '
        GROUP BY LOWER(TRIM(sp."Região"))
        ORDER BY COUNT(*) DESC';
END;
$$;


ALTER FUNCTION "public"."get_stats_regiao"("filter_instrument" "text", "filter_gender" "text", "filter_ethnicity" "text", "filter_age_range" "text", "filter_date_start" "text", "filter_date_end" "text", "filter_status" "text", "filter_classes" "text", "filter_programa" "text", "filter_teacher" "text", "filter_sponsor" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."get_stats_renda_familiar"() RETURNS TABLE("categoria" "text", "quantidade" bigint, "percentual" numeric)
    LANGUAGE "plpgsql"
    AS $$
DECLARE
    total_valido bigint;
BEGIN
    SELECT COUNT(*) INTO total_valido 
    FROM "Sociocultural Profile" 
    WHERE "renda familiar mensal" IS NOT NULL AND "renda familiar mensal" != '';
    
    RETURN QUERY
    SELECT 
        "renda familiar mensal" as categoria,
        COUNT(*) as quantidade,
        ROUND((COUNT(*) * 100.0 / NULLIF(total_valido, 0)), 2) as percentual
    FROM "Sociocultural Profile"
    WHERE "renda familiar mensal" IS NOT NULL AND "renda familiar mensal" != ''
    GROUP BY "renda familiar mensal"
    ORDER BY COUNT(*) DESC;
END;
$$;


ALTER FUNCTION "public"."get_stats_renda_familiar"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."get_stats_renda_familiar"("filter_instrument" "text" DEFAULT NULL::"text", "filter_gender" "text" DEFAULT NULL::"text", "filter_ethnicity" "text" DEFAULT NULL::"text", "filter_age_range" "text" DEFAULT NULL::"text", "filter_date_start" "text" DEFAULT NULL::"text", "filter_date_end" "text" DEFAULT NULL::"text", "filter_status" "text" DEFAULT NULL::"text", "filter_classes" "text" DEFAULT NULL::"text", "filter_programa" "text" DEFAULT NULL::"text", "filter_teacher" "text" DEFAULT NULL::"text", "filter_sponsor" "text" DEFAULT NULL::"text") RETURNS TABLE("categoria" "text", "quantidade" bigint, "percentual" integer)
    LANGUAGE "plpgsql"
    AS $$
DECLARE
    total_valido bigint;
    where_clause text := 'WHERE sp."renda familiar mensal" IS NOT NULL AND sp."renda familiar mensal" != ''''';
BEGIN
    IF filter_instrument IS NOT NULL THEN
        where_clause := where_clause || ' AND s."Instrument_Enroll_Form" = ' || quote_literal(filter_instrument);
    END IF;
    IF filter_gender IS NOT NULL THEN
        where_clause := where_clause || ' AND s."Gender" = ' || quote_literal(filter_gender);
    END IF;
    IF filter_ethnicity IS NOT NULL THEN
        where_clause := where_clause || ' AND s."Ethnicity" = ' || quote_literal(filter_ethnicity);
    END IF;
    IF filter_age_range IS NOT NULL THEN
        CASE filter_age_range
            WHEN '0-6' THEN where_clause := where_clause || ' AND s."Age_Number" BETWEEN 0 AND 6';
            WHEN '7-12' THEN where_clause := where_clause || ' AND s."Age_Number" BETWEEN 7 AND 12';
            WHEN '13-17' THEN where_clause := where_clause || ' AND s."Age_Number" BETWEEN 13 AND 17';
            WHEN '18-29' THEN where_clause := where_clause || ' AND s."Age_Number" BETWEEN 18 AND 29';
            WHEN '30-59' THEN where_clause := where_clause || ' AND s."Age_Number" BETWEEN 30 AND 59';
            WHEN '60+' THEN where_clause := where_clause || ' AND s."Age_Number" >= 60';
        END CASE;
    END IF;
    IF filter_date_start IS NOT NULL THEN
        where_clause := where_clause || ' AND s."Creation Date"::date >= ' || quote_literal(filter_date_start);
    END IF;
    IF filter_date_end IS NOT NULL THEN
        where_clause := where_clause || ' AND s."Creation Date"::date <= ' || quote_literal(filter_date_end);
    END IF;
    IF filter_status IS NOT NULL THEN
        where_clause := where_clause || ' AND s."Status" = ' || quote_literal(filter_status);
    END IF;
    IF filter_classes IS NOT NULL THEN
        where_clause := where_clause || ' AND s."Classes" = ' || quote_literal(filter_classes);
    END IF;
    IF filter_programa IS NOT NULL THEN
        where_clause := where_clause || ' AND s."Programa" = ' || quote_literal(filter_programa);
    END IF;
    IF filter_teacher IS NOT NULL THEN
        where_clause := where_clause || ' AND EXISTS (
            SELECT 1 FROM program_teachers pt
            WHERE pt.program_id = s."Programa"
            AND pt.teacher_unique_id = ' || quote_literal(filter_teacher) || ')';
    END IF;
    IF filter_sponsor IS NOT NULL THEN
        where_clause := where_clause || ' AND EXISTS (
            SELECT 1 FROM program_patrocinadores pp
            WHERE pp.program_id = s."Programa"
            AND pp.sponsor_id = ' || quote_literal(filter_sponsor) || ')';
    END IF;

    EXECUTE 'SELECT COUNT(*) FROM "Sociocultural Profile" sp
             INNER JOIN "Students" s ON sp.student = s."unique id" ' || where_clause INTO total_valido;

    RETURN QUERY EXECUTE
        'SELECT
            INITCAP(LOWER(TRIM(sp."renda familiar mensal"))) as categoria,
            COUNT(*) as quantidade,
            ROUND((COUNT(*) * 100.0 / NULLIF(' || total_valido || ', 0)))::integer as percentual
        FROM "Sociocultural Profile" sp
        INNER JOIN "Students" s ON sp.student = s."unique id" ' || where_clause || '
        GROUP BY LOWER(TRIM(sp."renda familiar mensal"))
        HAVING ROUND((COUNT(*) * 100.0 / NULLIF(' || total_valido || ', 0))) >= 5
        ORDER BY COUNT(*) DESC';
END;
$$;


ALTER FUNCTION "public"."get_stats_renda_familiar"("filter_instrument" "text", "filter_gender" "text", "filter_ethnicity" "text", "filter_age_range" "text", "filter_date_start" "text", "filter_date_end" "text", "filter_status" "text", "filter_classes" "text", "filter_programa" "text", "filter_teacher" "text", "filter_sponsor" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."get_stats_rendimentos_beneficios"() RETURNS TABLE("categoria" "text", "quantidade" bigint, "percentual" numeric)
    LANGUAGE "plpgsql"
    AS $$
DECLARE
    total_registros bigint;
BEGIN
    SELECT COUNT(*) INTO total_registros 
    FROM "Sociocultural Profile" 
    WHERE rendimentos_beneficios IS NOT NULL 
    AND rendimentos_beneficios != '';
    
    RETURN QUERY
    WITH items_expandidos AS (
        SELECT 
            TRIM(BOTH '"' FROM regexp_split_to_table(
                TRIM(BOTH '[]' FROM rendimentos_beneficios), 
                ','
            )) as item
        FROM "Sociocultural Profile"
        WHERE rendimentos_beneficios IS NOT NULL 
        AND rendimentos_beneficios != ''
    )
    SELECT 
        item as categoria,
        COUNT(*) as quantidade,
        ROUND((COUNT(*) * 100.0 / NULLIF(total_registros, 0)), 2) as percentual
    FROM items_expandidos
    WHERE item IS NOT NULL AND item != ''
    GROUP BY item
    ORDER BY COUNT(*) DESC;
END;
$$;


ALTER FUNCTION "public"."get_stats_rendimentos_beneficios"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."get_stats_rendimentos_beneficios"("filter_instrument" "text" DEFAULT NULL::"text", "filter_gender" "text" DEFAULT NULL::"text", "filter_ethnicity" "text" DEFAULT NULL::"text", "filter_age_range" "text" DEFAULT NULL::"text", "filter_date_start" "text" DEFAULT NULL::"text", "filter_date_end" "text" DEFAULT NULL::"text", "filter_status" "text" DEFAULT NULL::"text", "filter_classes" "text" DEFAULT NULL::"text", "filter_programa" "text" DEFAULT NULL::"text", "filter_teacher" "text" DEFAULT NULL::"text", "filter_sponsor" "text" DEFAULT NULL::"text") RETURNS TABLE("categoria" "text", "quantidade" bigint, "percentual" integer)
    LANGUAGE "plpgsql"
    AS $$
DECLARE
    total_registros bigint;
    where_clause text := 'WHERE sp.rendimento_beneficios_array IS NOT NULL AND jsonb_array_length(sp.rendimento_beneficios_array) > 0';
BEGIN
    IF filter_instrument IS NOT NULL THEN
        where_clause := where_clause || ' AND s."Instrument_Enroll_Form" = ' || quote_literal(filter_instrument);
    END IF;
    IF filter_gender IS NOT NULL THEN
        where_clause := where_clause || ' AND s."Gender" = ' || quote_literal(filter_gender);
    END IF;
    IF filter_ethnicity IS NOT NULL THEN
        where_clause := where_clause || ' AND s."Ethnicity" = ' || quote_literal(filter_ethnicity);
    END IF;
    IF filter_age_range IS NOT NULL THEN
        CASE filter_age_range
            WHEN '0-6' THEN where_clause := where_clause || ' AND s."Age_Number" BETWEEN 0 AND 6';
            WHEN '7-12' THEN where_clause := where_clause || ' AND s."Age_Number" BETWEEN 7 AND 12';
            WHEN '13-17' THEN where_clause := where_clause || ' AND s."Age_Number" BETWEEN 13 AND 17';
            WHEN '18-29' THEN where_clause := where_clause || ' AND s."Age_Number" BETWEEN 18 AND 29';
            WHEN '30-59' THEN where_clause := where_clause || ' AND s."Age_Number" BETWEEN 30 AND 59';
            WHEN '60+' THEN where_clause := where_clause || ' AND s."Age_Number" >= 60';
        END CASE;
    END IF;
    IF filter_date_start IS NOT NULL THEN
        where_clause := where_clause || ' AND s."Creation Date"::date >= ' || quote_literal(filter_date_start);
    END IF;
    IF filter_date_end IS NOT NULL THEN
        where_clause := where_clause || ' AND s."Creation Date"::date <= ' || quote_literal(filter_date_end);
    END IF;
    IF filter_status IS NOT NULL THEN
        where_clause := where_clause || ' AND s."Status" = ' || quote_literal(filter_status);
    END IF;
    IF filter_classes IS NOT NULL THEN
        where_clause := where_clause || ' AND s."Classes" = ' || quote_literal(filter_classes);
    END IF;
    IF filter_programa IS NOT NULL THEN
        where_clause := where_clause || ' AND s."Programa" = ' || quote_literal(filter_programa);
    END IF;
    IF filter_teacher IS NOT NULL THEN
        where_clause := where_clause || ' AND EXISTS (
            SELECT 1 FROM program_teachers pt
            WHERE pt.program_id = s."Programa"
            AND pt.teacher_unique_id = ' || quote_literal(filter_teacher) || ')';
    END IF;
    IF filter_sponsor IS NOT NULL THEN
        where_clause := where_clause || ' AND EXISTS (
            SELECT 1 FROM program_patrocinadores pp
            WHERE pp.program_id = s."Programa"
            AND pp.sponsor_id = ' || quote_literal(filter_sponsor) || ')';
    END IF;

    EXECUTE 'SELECT COUNT(*) FROM "Sociocultural Profile" sp
             INNER JOIN "Students" s ON sp.student = s."unique id" ' || where_clause INTO total_registros;

    RETURN QUERY EXECUTE
        'WITH normalized_items AS (
            SELECT
                CASE
                    WHEN COALESCE(TRIM(item::text), '''') = '''' THEN ''Sem Resposta''
                    ELSE INITCAP(LOWER(TRIM(item::text)))
                END as categoria_normalizada
            FROM "Sociocultural Profile" sp
            INNER JOIN "Students" s ON sp.student = s."unique id"
            CROSS JOIN LATERAL jsonb_array_elements_text(sp.rendimento_beneficios_array) as item ' ||
            where_clause || '
        )
        SELECT
            categoria_normalizada as categoria,
            COUNT(*)::bigint as quantidade,
            ROUND((COUNT(*) * 100.0 / NULLIF(' || total_registros || ', 0)))::integer as percentual
        FROM normalized_items
        GROUP BY categoria_normalizada
        HAVING ROUND((COUNT(*) * 100.0 / NULLIF(' || total_registros || ', 0))) >= 5
        ORDER BY COUNT(*) DESC';
END;
$$;


ALTER FUNCTION "public"."get_stats_rendimentos_beneficios"("filter_instrument" "text", "filter_gender" "text", "filter_ethnicity" "text", "filter_age_range" "text", "filter_date_start" "text", "filter_date_end" "text", "filter_status" "text", "filter_classes" "text", "filter_programa" "text", "filter_teacher" "text", "filter_sponsor" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."get_stats_servicos_politicas"() RETURNS TABLE("categoria" "text", "quantidade" bigint, "percentual" numeric)
    LANGUAGE "plpgsql"
    AS $$
DECLARE
    total_registros bigint;
BEGIN
    SELECT COUNT(*) INTO total_registros 
    FROM "Sociocultural Profile" 
    WHERE "Serviços_politicas" IS NOT NULL 
    AND "Serviços_politicas" != '';
    
    RETURN QUERY
    WITH items_expandidos AS (
        SELECT 
            TRIM(BOTH '"' FROM regexp_split_to_table(
                TRIM(BOTH '[]' FROM "Serviços_politicas"), 
                ','
            )) as item
        FROM "Sociocultural Profile"
        WHERE "Serviços_politicas" IS NOT NULL 
        AND "Serviços_politicas" != ''
    )
    SELECT 
        item as categoria,
        COUNT(*) as quantidade,
        ROUND((COUNT(*) * 100.0 / NULLIF(total_registros, 0)), 2) as percentual
    FROM items_expandidos
    WHERE item IS NOT NULL AND item != ''
    GROUP BY item
    ORDER BY COUNT(*) DESC;
END;
$$;


ALTER FUNCTION "public"."get_stats_servicos_politicas"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."get_stats_servicos_politicas"("filter_instrument" "text" DEFAULT NULL::"text", "filter_gender" "text" DEFAULT NULL::"text", "filter_ethnicity" "text" DEFAULT NULL::"text", "filter_age_range" "text" DEFAULT NULL::"text", "filter_date_start" "text" DEFAULT NULL::"text", "filter_date_end" "text" DEFAULT NULL::"text", "filter_status" "text" DEFAULT NULL::"text", "filter_classes" "text" DEFAULT NULL::"text", "filter_programa" "text" DEFAULT NULL::"text", "filter_teacher" "text" DEFAULT NULL::"text", "filter_sponsor" "text" DEFAULT NULL::"text") RETURNS TABLE("categoria" "text", "quantidade" bigint, "percentual" integer)
    LANGUAGE "plpgsql"
    AS $$
DECLARE
    total_registros bigint;
    where_clause text := 'WHERE sp.servicos_politicas_array IS NOT NULL AND jsonb_array_length(sp.servicos_politicas_array) > 0';
BEGIN
    IF filter_instrument IS NOT NULL THEN
        where_clause := where_clause || ' AND s."Instrument_Enroll_Form" = ' || quote_literal(filter_instrument);
    END IF;
    IF filter_gender IS NOT NULL THEN
        where_clause := where_clause || ' AND s."Gender" = ' || quote_literal(filter_gender);
    END IF;
    IF filter_ethnicity IS NOT NULL THEN
        where_clause := where_clause || ' AND s."Ethnicity" = ' || quote_literal(filter_ethnicity);
    END IF;
    IF filter_age_range IS NOT NULL THEN
        CASE filter_age_range
            WHEN '0-6' THEN where_clause := where_clause || ' AND s."Age_Number" BETWEEN 0 AND 6';
            WHEN '7-12' THEN where_clause := where_clause || ' AND s."Age_Number" BETWEEN 7 AND 12';
            WHEN '13-17' THEN where_clause := where_clause || ' AND s."Age_Number" BETWEEN 13 AND 17';
            WHEN '18-29' THEN where_clause := where_clause || ' AND s."Age_Number" BETWEEN 18 AND 29';
            WHEN '30-59' THEN where_clause := where_clause || ' AND s."Age_Number" BETWEEN 30 AND 59';
            WHEN '60+' THEN where_clause := where_clause || ' AND s."Age_Number" >= 60';
        END CASE;
    END IF;
    IF filter_date_start IS NOT NULL THEN
        where_clause := where_clause || ' AND s."Creation Date"::date >= ' || quote_literal(filter_date_start);
    END IF;
    IF filter_date_end IS NOT NULL THEN
        where_clause := where_clause || ' AND s."Creation Date"::date <= ' || quote_literal(filter_date_end);
    END IF;
    IF filter_status IS NOT NULL THEN
        where_clause := where_clause || ' AND s."Status" = ' || quote_literal(filter_status);
    END IF;
    IF filter_classes IS NOT NULL THEN
        where_clause := where_clause || ' AND s."Classes" = ' || quote_literal(filter_classes);
    END IF;
    IF filter_programa IS NOT NULL THEN
        where_clause := where_clause || ' AND s."Programa" = ' || quote_literal(filter_programa);
    END IF;
    IF filter_teacher IS NOT NULL THEN
        where_clause := where_clause || ' AND EXISTS (
            SELECT 1 FROM program_teachers pt
            WHERE pt.program_id = s."Programa"
            AND pt.teacher_unique_id = ' || quote_literal(filter_teacher) || ')';
    END IF;
    IF filter_sponsor IS NOT NULL THEN
        where_clause := where_clause || ' AND EXISTS (
            SELECT 1 FROM program_patrocinadores pp
            WHERE pp.program_id = s."Programa"
            AND pp.sponsor_id = ' || quote_literal(filter_sponsor) || ')';
    END IF;

    EXECUTE 'SELECT COUNT(*) FROM "Sociocultural Profile" sp
             INNER JOIN "Students" s ON sp.student = s."unique id" ' || where_clause INTO total_registros;

    RETURN QUERY EXECUTE
        'SELECT
            INITCAP(LOWER(TRIM(item::text))) as categoria,
            COUNT(*) as quantidade,
            ROUND((COUNT(*) * 100.0 / NULLIF(' || total_registros || ', 0)))::integer as percentual
        FROM "Sociocultural Profile" sp
        INNER JOIN "Students" s ON sp.student = s."unique id"
        CROSS JOIN LATERAL jsonb_array_elements_text(sp.servicos_politicas_array) as item ' ||
        where_clause || '
        GROUP BY LOWER(TRIM(item::text))
        HAVING ROUND((COUNT(*) * 100.0 / NULLIF(' || total_registros || ', 0))) >= 5
        ORDER BY COUNT(*) DESC';
END;
$$;


ALTER FUNCTION "public"."get_stats_servicos_politicas"("filter_instrument" "text", "filter_gender" "text", "filter_ethnicity" "text", "filter_age_range" "text", "filter_date_start" "text", "filter_date_end" "text", "filter_status" "text", "filter_classes" "text", "filter_programa" "text", "filter_teacher" "text", "filter_sponsor" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."get_student_survey_stats"("p_city" "text" DEFAULT NULL::"text", "p_state" "text" DEFAULT NULL::"text", "p_class" "text" DEFAULT NULL::"text", "p_program" "text" DEFAULT NULL::"text", "p_start_date" "date" DEFAULT NULL::"date", "p_end_date" "date" DEFAULT NULL::"date", "p_include_total" boolean DEFAULT true) RETURNS "jsonb"
    LANGUAGE "plpgsql"
    AS $$
DECLARE
  result jsonb := '{}'::jsonb;
  q record;
  o record;
  sql_base text;
  sql text;
  total_global int;
  total_global_filtered int;
  total_question_filtered int;
  count_value numeric;
  avg_score_global numeric;
  avg_score_question numeric;
BEGIN
  -- Total global SEM filtros
  EXECUTE 'SELECT count(*) FROM survey_sinta_o_som_aluno' INTO total_global;
  IF total_global IS NULL THEN total_global := 0; END IF;

  -- Total global COM filtros
  sql_base := 'FROM survey_sinta_o_som_aluno s WHERE 1=1';
  IF p_city IS NOT NULL THEN sql_base := sql_base || format(' AND s.cidade = %L', p_city); END IF;
  IF p_state IS NOT NULL THEN sql_base := sql_base || format(' AND s.estado = %L', p_state); END IF;
  IF p_class IS NOT NULL THEN sql_base := sql_base || format(' AND s.class = %L', p_class); END IF;
  IF p_program IS NOT NULL THEN sql_base := sql_base || format(' AND s.program = %L', p_program); END IF;
  IF p_start_date IS NOT NULL THEN sql_base := sql_base || format(' AND s.created_date >= %L::date', p_start_date); END IF;
  IF p_end_date IS NOT NULL THEN sql_base := sql_base || format(' AND s.created_date <= %L::date', p_end_date); END IF;

  EXECUTE 'SELECT count(*) ' || sql_base INTO total_global_filtered;
  IF total_global_filtered IS NULL THEN total_global_filtered := 0; END IF;

  -- Média geral do score COM filtros
  EXECUTE 'SELECT AVG(s.score) ' || sql_base INTO avg_score_global;
  IF avg_score_global IS NULL THEN avg_score_global := 0; END IF;

  -- Loop das perguntas
  FOR q IN (
    SELECT * FROM (VALUES
      ('colabora_com_colegas'),
      ('cultura_da_regiao'),
      ('curiosidade_por_musica'),
      ('empatia_com_colegas'),
      ('entusiasmo'),
      ('expressar_em_publico'),
      ('interesse_manifetacoes'),
      ('interesse_tema_div_cultural'),
      ('liderança'),
      ('participa_atividades_culturais'),
      ('persistencia')
    ) AS t(question)
  ) LOOP
    
    -- Total filtrado por pergunta
    EXECUTE 'SELECT count(*) ' || sql_base || format(' AND s.%I IS NOT NULL', q.question)
    INTO total_question_filtered;
    IF total_question_filtered IS NULL THEN total_question_filtered := 0; END IF;

    -- Média do score por pergunta COM filtros
    EXECUTE 'SELECT AVG(s.score) ' || sql_base || format(' AND s.%I IS NOT NULL', q.question)
    INTO avg_score_question;
    IF avg_score_question IS NULL THEN avg_score_question := 0; END IF;

    -- Array inicial
    result := jsonb_set(result, ARRAY[q.question], '[]'::jsonb, TRUE);

    -- Percentuais por opção
    FOR o IN (
      SELECT * FROM (VALUES
        ('Não houve melhora observável', 1),
        ('Houve melhora discreta', 2),
        ('Houve melhora moderada', 3),
        ('Houve melhora significativa', 4)
      ) AS opts(option, rank)
      ORDER BY rank
    ) LOOP
      
      sql := 'SELECT count(*) ' || sql_base || format(' AND s.%I = %L', q.question, o.option);
      EXECUTE sql INTO count_value;

      result := jsonb_set(
        result, ARRAY[q.question],
        (
          result -> q.question
          || jsonb_build_object(
              'option', o.option,
              'percent',
                CASE WHEN total_question_filtered = 0 THEN 0
                     ELSE round((count_value / total_question_filtered) * 100, 2)
                END,
              'total_filtered', total_question_filtered
            )
        )::jsonb,
        FALSE
      );
    END LOOP;

    -- Adicionar média do score por pergunta
    result := jsonb_set(
      result, ARRAY[q.question],
      (result -> q.question || jsonb_build_object('avg_score', round(avg_score_question, 2)))::jsonb,
      FALSE
    );

  END LOOP;

  -- SEMPRE retorna totais (ignora p_include_total)
  result := result || jsonb_build_object(
    'total_count', total_global,
    'total_filtered', total_global_filtered,
    'avg_score_global', round(avg_score_global, 2)
  );

  RETURN result;
END;
$$;


ALTER FUNCTION "public"."get_student_survey_stats"("p_city" "text", "p_state" "text", "p_class" "text", "p_program" "text", "p_start_date" "date", "p_end_date" "date", "p_include_total" boolean) OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."get_student_unique_id_by_name_dob"("p_fullname" "text", "p_dob" "text") RETURNS TABLE("unique_id" "text")
    LANGUAGE "sql"
    AS $$
SELECT
    "unique id"
FROM
    public."Students"
WHERE
    unaccent(LOWER(TRIM(fullname))) = unaccent(LOWER(TRIM(p_fullname)))
    -- Use TO_DATE se o formato for diferente de YYYY-MM-DD
    AND CAST("DOB" AS DATE) = CAST(p_dob AS DATE)
LIMIT 1;
$$;


ALTER FUNCTION "public"."get_student_unique_id_by_name_dob"("p_fullname" "text", "p_dob" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."get_survey_monitoramento_sinta_som_report"("p_class" "text" DEFAULT NULL::"text", "p_program" "text" DEFAULT NULL::"text", "p_uf" "text" DEFAULT NULL::"text", "p_cidade" "text" DEFAULT NULL::"text", "p_start_date" "date" DEFAULT NULL::"date", "p_end_date" "date" DEFAULT NULL::"date") RETURNS "jsonb"
    LANGUAGE "plpgsql"
    AS $$
declare
  result jsonb := '{}'::jsonb;
  sql_base text;
  sql text;
  total_global int := 0;
  total_global_filtered int := 0;
  total_question_filtered int := 0;
  count_value numeric := 0;
  r record;
begin
  ------------------------------------------------------------------
  -- TOTAL GLOBAL SEM FILTROS
  ------------------------------------------------------------------
  select count(*) into total_global
  from public.survey_monitoramento_sinta_som;

  if total_global is null then total_global := 0; end if;

  ------------------------------------------------------------------
  -- SQL BASE COM FILTROS
  ------------------------------------------------------------------
  sql_base := 'from public.survey_monitoramento_sinta_som s where 1=1';

  if p_class is not null then
    sql_base := sql_base || format(' and s.class = %L', p_class);
  end if;

  if p_program is not null then
    sql_base := sql_base || format(' and s.program = %L', p_program);
  end if;

  if p_uf is not null then
    sql_base := sql_base || format(' and s.uf = %L', p_uf);
  end if;

  if p_cidade is not null then
    sql_base := sql_base || format(' and s.cidade = %L', p_cidade);
  end if;

  if p_start_date is not null then
    sql_base := sql_base || format(' and s.created_date >= %L::date', p_start_date);
  end if;

  if p_end_date is not null then
    sql_base := sql_base || format(' and s.created_date <= %L::date', p_end_date);
  end if;

  ------------------------------------------------------------------
  -- TOTAL GLOBAL COM FILTROS
  ------------------------------------------------------------------
  execute 'select count(*) ' || sql_base into total_global_filtered;

  if total_global_filtered is null then total_global_filtered := 0; end if;


  ------------------------------------------------------------------
  -- 1) NÍVEL DE PARTICIPAÇÃO  (nivel_entusiasmo)
  ------------------------------------------------------------------
  execute 'select count(*) ' || sql_base || ' and s.nivel_entusiasmo is not null'
    into total_question_filtered;

  if total_question_filtered is null then total_question_filtered := 0; end if;

  result := jsonb_set(result, '{nivel_participacao}', '[]'::jsonb, true);

  for r in
    select v as option
    from (values ('Baixo'), ('Médio'), ('Alto')) as t(v)
  loop
    sql := 'select count(*) ' || sql_base ||
           format(' and s.nivel_entusiasmo = %L', r.option);

    execute sql into count_value;

    result := jsonb_set(
      result,
      '{nivel_participacao}',
      (
        result -> 'nivel_participacao'
        || jsonb_build_object(
             'option', r.option,
             'percent',
              case when total_question_filtered = 0 then 0
                   else round((count_value::numeric / total_question_filtered::numeric) * 100, 2)
              end,
             'total_filtered', total_question_filtered
           )
      )::jsonb,
      false
    );
  end loop;


  ------------------------------------------------------------------
  -- 2) NECESSIDADES E DESAFIOS
  ------------------------------------------------------------------
  execute 'select count(*) ' || sql_base || ' and s.necessidades_desafios is not null'
    into total_question_filtered;

  if total_question_filtered is null then total_question_filtered := 0; end if;

  result := jsonb_set(result, '{necessidades_desafios}', '[]'::jsonb, true);

  for r in
    select v as option
    from (
      values
        ('Sim - falta de material'),
        ('Sim - espaço impróprio'),
        ('Sim - a indisciplina da turma e falta de suporte da unidade'),
        ('Não')
    ) as t(v)
  loop
    sql := 'select count(*) ' || sql_base ||
           format(' and s.necessidades_desafios = %L', r.option);

    execute sql into count_value;

    result := jsonb_set(
      result,
      '{necessidades_desafios}',
      (
        result -> 'necessidades_desafios'
        || jsonb_build_object(
             'option', r.option,
             'percent',
              case when total_question_filtered = 0 then 0
                   else round((count_value::numeric / total_question_filtered::numeric) * 100, 2)
              end,
             'total_filtered', total_question_filtered
           )
      )::jsonb,
      false
    );
  end loop;


  ------------------------------------------------------------------
  -- 3) TOTAL DE ALUNOS (BUCKETS)
  ------------------------------------------------------------------
  execute 'select count(*) ' || sql_base || ' and s.total_alunos is not null'
    into total_question_filtered;

  if total_question_filtered is null then total_question_filtered := 0; end if;

  result := jsonb_set(result, '{total_alunos}', '[]'::jsonb, true);


  -- 3.1) 0 a 10
  sql := 'select count(*) ' || sql_base || ' and s.total_alunos >= 0 and s.total_alunos <= 10';
  execute sql into count_value;

  result := jsonb_set(
    result,
    '{total_alunos}',
    (
      result -> 'total_alunos'
      || jsonb_build_object(
           'range', '0 a 10',
           'percent',
            case when total_question_filtered = 0 then 0
                 else round((count_value::numeric / total_question_filtered::numeric) * 100, 2)
            end,
           'total_filtered', total_question_filtered
         )
    )::jsonb,
    false
  );

  -- 3.2) 10 a 50
  sql := 'select count(*) ' || sql_base || ' and s.total_alunos > 10 and s.total_alunos <= 50';
  execute sql into count_value;

  result := jsonb_set(
    result,
    '{total_alunos}',
    (
      result -> 'total_alunos'
      || jsonb_build_object(
           'range', '10 a 50',
           'percent',
            case when total_question_filtered = 0 then 0
                 else round((count_value::numeric / total_question_filtered::numeric) * 100, 2)
            end,
           'total_filtered', total_question_filtered
         )
    )::jsonb,
    false
  );

  -- 3.3) 50 a 100
  sql := 'select count(*) ' || sql_base || ' and s.total_alunos > 50 and s.total_alunos <= 100';
  execute sql into count_value;

  result := jsonb_set(
    result,
    '{total_alunos}',
    (
      result -> 'total_alunos'
      || jsonb_build_object(
           'range', '50 a 100',
           'percent',
            case when total_question_filtered = 0 then 0
                 else round((count_value::numeric / total_question_filtered::numeric) * 100, 2)
            end,
           'total_filtered', total_question_filtered
         )
    )::jsonb,
    false
  );

  -- 3.4) Mais que 100
  sql := 'select count(*) ' || sql_base || ' and s.total_alunos > 100';
  execute sql into count_value;

  result := jsonb_set(
    result,
    '{total_alunos}',
    (
      result -> 'total_alunos'
      || jsonb_build_object(
           'range', 'Mais que 100',
           'percent',
            case when total_question_filtered = 0 then 0
                 else round((count_value::numeric / total_question_filtered::numeric) * 100, 2)
            end,
           'total_filtered', total_question_filtered
         )
    )::jsonb,
    false
  );


  ------------------------------------------------------------------
  -- 4) LISTA DE MÍDIAS (SOMENTE URLs)
  ------------------------------------------------------------------
  result := jsonb_set(result, '{media}', '[]'::jsonb, true);

  sql := '
    select m.url
    from public.rel_media_survey_monitoramento_sinta_som m
    join public.survey_monitoramento_sinta_som s
      on s.unique_id = m.survey_unique_id
    where 1=1';

  if p_class is not null then
    sql := sql || format(' and s.class = %L', p_class);
  end if;

  if p_program is not null then
    sql := sql || format(' and s.program = %L', p_program);
  end if;

  if p_uf is not null then
    sql := sql || format(' and s.uf = %L', p_uf);
  end if;

  if p_cidade is not null then
    sql := sql || format(' and s.cidade = %L', p_cidade);
  end if;

  if p_start_date is not null then
    sql := sql || format(' and s.created_date >= %L::date', p_start_date);
  end if;

  if p_end_date is not null then
    sql := sql || format(' and s.created_date <= %L::date', p_end_date);
  end if;

  for r in execute sql loop
    result := jsonb_set(
      result,
      '{media}',
      (
        result -> 'media'
        || to_jsonb(r.url)
      )::jsonb,
      false
    );
  end loop;


  ------------------------------------------------------------------
  -- TOTAL FINAL DO JSON
  ------------------------------------------------------------------
  result := result || jsonb_build_object(
    'total_count', total_global,
    'total_filtered', total_global_filtered
  );

  return result;
end;
$$;


ALTER FUNCTION "public"."get_survey_monitoramento_sinta_som_report"("p_class" "text", "p_program" "text", "p_uf" "text", "p_cidade" "text", "p_start_date" "date", "p_end_date" "date") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."get_survey_sinta_o_som_stats"("p_city" "text" DEFAULT NULL::"text", "p_state" "text" DEFAULT NULL::"text", "p_class" "text" DEFAULT NULL::"text", "p_program" "text" DEFAULT NULL::"text", "p_start_date" "date" DEFAULT NULL::"date", "p_end_date" "date" DEFAULT NULL::"date", "p_include_total" boolean DEFAULT true) RETURNS "jsonb"
    LANGUAGE "plpgsql" STABLE
    AS $$
DECLARE
  result jsonb := '{}'::jsonb;
  q record;
  o record;
  sql_base text;
  sql text;
  total_global int;
  total_global_filtered int;
  total_question_filtered int;
  count_value numeric;
  avg_score_global numeric;
  avg_score_question numeric;
BEGIN
  -- Total global SEM filtros
  EXECUTE 'SELECT count(*) FROM survey_sinta_o_som_aluno' INTO total_global;
  IF total_global IS NULL THEN total_global := 0; END IF;

  -- Total global COM filtros
  sql_base := 'FROM survey_sinta_o_som_aluno s WHERE 1=1';
  
  IF p_city IS NOT NULL AND p_city <> '' THEN 
    sql_base := sql_base || format(' AND TRIM(s.cidade) = %L', TRIM(p_city)); 
  END IF;
  
  IF p_state IS NOT NULL AND p_state <> '' THEN 
    sql_base := sql_base || format(' AND TRIM(s.estado) = %L', TRIM(p_state)); 
  END IF;
  
  IF p_class IS NOT NULL AND p_class <> '' THEN 
    sql_base := sql_base || format(' AND TRIM(s.class) = %L', TRIM(p_class)); 
  END IF;
  
  IF p_program IS NOT NULL AND p_program <> '' THEN 
    sql_base := sql_base || format(' AND TRIM(s.program) = %L', TRIM(p_program)); 
  END IF;
  
  IF p_start_date IS NOT NULL THEN 
    sql_base := sql_base || format(' AND s.created_date::date >= %L', p_start_date); 
  END IF;
  
  IF p_end_date IS NOT NULL THEN 
    sql_base := sql_base || format(' AND s.created_date::date <= %L', p_end_date); 
  END IF;

  EXECUTE 'SELECT count(*) ' || sql_base INTO total_global_filtered;
  IF total_global_filtered IS NULL THEN total_global_filtered := 0; END IF;

  -- Média geral do score COM filtros
  EXECUTE 'SELECT AVG(s.score::numeric) ' || sql_base INTO avg_score_global;
  IF avg_score_global IS NULL THEN avg_score_global := 0; END IF;

  -- Loop das perguntas
  FOR q IN (
    SELECT * FROM (VALUES
      ('colabora_com_colegas'),
      ('cultura_da_regiao'),
      ('curiosidade_por_musica'),
      ('empatia_com_colegas'),
      ('entusiasmo'),
      ('expressar_em_publico'),
      ('interesse_manifetacoes'),
      ('interesse_tema_div_cultural'),
      ('liderança'),
      ('participa_atividades_culturais'),
      ('persistencia')
    ) AS t(question)
  ) LOOP
    
    -- Total filtrado por pergunta
    EXECUTE 'SELECT count(*) ' || sql_base || format(' AND s.%I IS NOT NULL AND s.%I <> ''''', q.question, q.question)
    INTO total_question_filtered;
    IF total_question_filtered IS NULL THEN total_question_filtered := 0; END IF;

    -- Média do score por pergunta COM filtros
    EXECUTE 'SELECT AVG(s.score::numeric) ' || sql_base || format(' AND s.%I IS NOT NULL AND s.%I <> ''''', q.question, q.question)
    INTO avg_score_question;
    IF avg_score_question IS NULL THEN avg_score_question := 0; END IF;

    -- Array inicial
    result := jsonb_set(result, ARRAY[q.question], '[]'::jsonb, TRUE);

    -- Percentuais por opção
    FOR o IN (
      SELECT * FROM (VALUES
        ('Não houve melhora observável', 1),
        ('Houve melhora discreta', 2),
        ('Houve melhora moderada', 3),
        ('Houve melhora significativa', 4)
      ) AS opts(option, rank)
      ORDER BY rank
    ) LOOP
      
      sql := 'SELECT count(*) ' || sql_base || format(' AND TRIM(s.%I) = %L', q.question, o.option);
      EXECUTE sql INTO count_value;
      IF count_value IS NULL THEN count_value := 0; END IF;

      result := jsonb_set(
        result, ARRAY[q.question],
        (
          result -> q.question
          || jsonb_build_object(
              'option', o.option,
              'percent',
                CASE WHEN total_question_filtered = 0 THEN 0
                     ELSE round((count_value / total_question_filtered::numeric) * 100, 2)
                END,
              'count', count_value,
              'total_filtered', total_question_filtered
            )
        )::jsonb,
        FALSE
      );
    END LOOP;

    -- Adicionar média do score por pergunta
    result := jsonb_set(
      result, ARRAY[q.question],
      (result -> q.question || jsonb_build_object('avg_score', round(avg_score_question, 2)))::jsonb,
      FALSE
    );

  END LOOP;

  -- SEMPRE retorna totais
  result := result || jsonb_build_object(
    'total_count', total_global,
    'total_filtered', total_global_filtered,
    'avg_score_global', round(avg_score_global, 2)
  );

  RETURN result;
END;
$$;


ALTER FUNCTION "public"."get_survey_sinta_o_som_stats"("p_city" "text", "p_state" "text", "p_class" "text", "p_program" "text", "p_start_date" "date", "p_end_date" "date", "p_include_total" boolean) OWNER TO "postgres";


COMMENT ON FUNCTION "public"."get_survey_sinta_o_som_stats"("p_city" "text", "p_state" "text", "p_class" "text", "p_program" "text", "p_start_date" "date", "p_end_date" "date", "p_include_total" boolean) IS 'Retorna estatísticas da pesquisa Sinta o Som (alunos) com filtros opcionais';



CREATE OR REPLACE FUNCTION "public"."get_teacher_impact_survey_stats"("p_city" "text" DEFAULT NULL::"text", "p_state" "text" DEFAULT NULL::"text", "p_program" "text" DEFAULT NULL::"text", "p_teacher" "text" DEFAULT NULL::"text", "p_start_date" "date" DEFAULT NULL::"date", "p_end_date" "date" DEFAULT NULL::"date", "p_include_total" boolean DEFAULT true) RETURNS "jsonb"
    LANGUAGE "plpgsql"
    AS $$
DECLARE
  result jsonb := '{}'::jsonb;
  q record;
  o record;
  sql_base text;
  sql text;
  total_global int := 0;
  total_global_filtered int := 0;
  total_question_filtered int := 0;
  count_value numeric := 0;
  avg_score_global numeric := 0;
  avg_score_question numeric := 0;

  -- Variáveis para KPIs
  kpi_geral numeric := 0;
  kpi_grupo_1 numeric := 0;
  kpi_grupo_2 numeric := 0;

  -- Mapeamento de scores: Discordo totalmente=0, Discordo parcialmente=1, Concordo parcialmente=2, Concordo totalmente=3
  question_score numeric := 0;

BEGIN
  -- Total global SEM filtros
  EXECUTE 'SELECT count(*) FROM public.teacher_impact_survey' INTO total_global;

  -- SQL base com filtros
  sql_base := 'FROM public.teacher_impact_survey s WHERE 1=1';

  IF p_city IS NOT NULL AND p_city <> '' THEN
    sql_base := sql_base || format(' AND (TRIM(COALESCE(s.cidade, '''')) = %L OR s.cidade IS NULL)', TRIM(p_city));
  END IF;

  IF p_state IS NOT NULL AND p_state <> '' THEN
    sql_base := sql_base || format(' AND (TRIM(COALESCE(s.estado, '''')) = %L OR s.estado IS NULL)', TRIM(p_state));
  END IF;

  IF p_program IS NOT NULL AND p_program <> '' THEN
    sql_base := sql_base || format(' AND (TRIM(COALESCE(s.programa, '''')) = %L OR s.programa IS NULL)', TRIM(p_program));
  END IF;

  IF p_teacher IS NOT NULL AND p_teacher <> '' THEN
    sql_base := sql_base || format(' AND (TRIM(COALESCE(s.teacher, '''')) = %L OR s.teacher IS NULL)', TRIM(p_teacher));
  END IF;

  IF p_start_date IS NOT NULL THEN
    sql_base := sql_base || format(' AND s.created_date::date >= %L', p_start_date);
  END IF;

  IF p_end_date IS NOT NULL THEN
    sql_base := sql_base || format(' AND s.created_date::date <= %L', p_end_date);
  END IF;

  -- Totais filtrados
  EXECUTE 'SELECT count(*) ' || sql_base INTO total_global_filtered;

  -- Média geral do score (calculada baseada em todas as respostas válidas)
  -- Calcula média de todas as respostas de todas as perguntas - ESCALA 0-3
  EXECUTE '
    SELECT AVG(
      CASE
        WHEN response = ''Discordo totalmente'' THEN 0
        WHEN response = ''Discordo parcialmente'' THEN 1
        WHEN response = ''Concordo parcialmente'' THEN 2
        WHEN response = ''Concordo totalmente'' THEN 3
        ELSE NULL
      END
    )
    FROM (
      SELECT s."sentir se preparado" as response ' || sql_base || ' AND s."sentir se preparado" IS NOT NULL
      UNION ALL
      SELECT s."confianca" ' || sql_base || ' AND s."confianca" IS NOT NULL
      UNION ALL
      SELECT s."seguranca com jogos musicais" ' || sql_base || ' AND s."seguranca com jogos musicais" IS NOT NULL
      UNION ALL
      SELECT s."formacoes" ' || sql_base || ' AND s."formacoes" IS NOT NULL
      UNION ALL
      SELECT s."materiais didaticos" ' || sql_base || ' AND s."materiais didaticos" IS NOT NULL
      UNION ALL
      SELECT s."integracao repertorio e atividades" ' || sql_base || ' AND s."integracao repertorio e atividades" IS NOT NULL
      UNION ALL
      SELECT s."atividades musicais" ' || sql_base || ' AND s."atividades musicais" IS NOT NULL
      UNION ALL
      SELECT s."engajamento dos alunos" ' || sql_base || ' AND s."engajamento dos alunos" IS NOT NULL
      UNION ALL
      SELECT s."adaptacao da proposta com realidade" ' || sql_base || ' AND s."adaptacao da proposta com realidade" IS NOT NULL
      UNION ALL
      SELECT s."participacao" ' || sql_base || ' AND s."participacao" IS NOT NULL
    ) all_responses
  ' INTO avg_score_global;
  IF avg_score_global IS NULL THEN avg_score_global := 0; END IF;

  -- ============================================================================
  -- CÁLCULO DOS KPIs - ESCALA 0-3
  -- ============================================================================

  -- KPI GERAL: Média de todas as 10 perguntas
  kpi_geral := avg_score_global;

  -- KPI GRUPO 1: Média das 6 perguntas específicas
  -- sentir se preparado, confianca, seguranca com jogos musicais,
  -- participacao, materiais didaticos, integracao repertorio e atividades
  EXECUTE '
    SELECT
      AVG(
        CASE
          WHEN q.response = ''Discordo totalmente'' THEN 0
          WHEN q.response = ''Discordo parcialmente'' THEN 1
          WHEN q.response = ''Concordo parcialmente'' THEN 2
          WHEN q.response = ''Concordo totalmente'' THEN 3
          ELSE NULL
        END
      )
    FROM (
      SELECT s."sentir se preparado" as response ' || sql_base || ' AND s."sentir se preparado" IS NOT NULL
      UNION ALL
      SELECT s."confianca" ' || sql_base || ' AND s."confianca" IS NOT NULL
      UNION ALL
      SELECT s."seguranca com jogos musicais" ' || sql_base || ' AND s."seguranca com jogos musicais" IS NOT NULL
      UNION ALL
      SELECT s."participacao" ' || sql_base || ' AND s."participacao" IS NOT NULL
      UNION ALL
      SELECT s."materiais didaticos" ' || sql_base || ' AND s."materiais didaticos" IS NOT NULL
      UNION ALL
      SELECT s."integracao repertorio e atividades" ' || sql_base || ' AND s."integracao repertorio e atividades" IS NOT NULL
    ) q
  ' INTO kpi_grupo_1;

  IF kpi_grupo_1 IS NULL THEN kpi_grupo_1 := 0; END IF;

  -- KPI GRUPO 2: Média das 4 perguntas restantes
  -- adaptacao da proposta com realidade, atividades musicais,
  -- engajamento dos alunos, formacoes
  EXECUTE '
    SELECT
      AVG(
        CASE
          WHEN q.response = ''Discordo totalmente'' THEN 0
          WHEN q.response = ''Discordo parcialmente'' THEN 1
          WHEN q.response = ''Concordo parcialmente'' THEN 2
          WHEN q.response = ''Concordo totalmente'' THEN 3
          ELSE NULL
        END
      )
    FROM (
      SELECT s."adaptacao da proposta com realidade" as response ' || sql_base || ' AND s."adaptacao da proposta com realidade" IS NOT NULL
      UNION ALL
      SELECT s."atividades musicais" ' || sql_base || ' AND s."atividades musicais" IS NOT NULL
      UNION ALL
      SELECT s."engajamento dos alunos" ' || sql_base || ' AND s."engajamento dos alunos" IS NOT NULL
      UNION ALL
      SELECT s."formacoes" ' || sql_base || ' AND s."formacoes" IS NOT NULL
    ) q
  ' INTO kpi_grupo_2;

  IF kpi_grupo_2 IS NULL THEN kpi_grupo_2 := 0; END IF;

  -- ============================================================================
  -- LOOP DAS PERGUNTAS (mantém comportamento original)
  -- ============================================================================

  FOR q IN (
    SELECT * FROM (VALUES
      ('adaptacao da proposta com realidade'),
      ('atividades musicais'),
      ('confianca'),
      ('engajamento dos alunos'),
      ('formacoes'),
      ('integracao repertorio e atividades'),
      ('materiais didaticos'),
      ('participacao'),
      ('seguranca com jogos musicais'),
      ('sentir se preparado')
    ) AS t(question)
  ) LOOP

    -- Total filtrado por pergunta
    EXECUTE 'SELECT count(*) ' || sql_base || format(' AND s.%I IS NOT NULL AND s.%I <> ''''', q.question, q.question)
    INTO total_question_filtered;

    IF total_question_filtered IS NULL THEN total_question_filtered := 0; END IF;

    -- Média do score por pergunta (calculado baseado nas respostas) - ESCALA 0-3
    EXECUTE '
      SELECT AVG(
        CASE
          WHEN s.' || quote_ident(q.question) || ' = ''Discordo totalmente'' THEN 0
          WHEN s.' || quote_ident(q.question) || ' = ''Discordo parcialmente'' THEN 1
          WHEN s.' || quote_ident(q.question) || ' = ''Concordo parcialmente'' THEN 2
          WHEN s.' || quote_ident(q.question) || ' = ''Concordo totalmente'' THEN 3
          ELSE NULL
        END
      )
    ' || sql_base || format(' AND s.%I IS NOT NULL AND s.%I <> ''''', q.question, q.question)
    INTO avg_score_question;

    IF avg_score_question IS NULL THEN avg_score_question := 0; END IF;

    -- Array inicial
    result := jsonb_set(result, ARRAY[q.question], '[]'::jsonb, TRUE);

    -- Percentuais por opção
    FOR o IN (
      SELECT * FROM (VALUES
        ('Discordo totalmente', 1),
        ('Discordo parcialmente', 2),
        ('Concordo parcialmente', 3),
        ('Concordo totalmente', 4)
      ) AS opts(option, rank)
      ORDER BY rank
    ) LOOP

      sql := 'SELECT count(*) ' || sql_base || format(' AND TRIM(s.%I) = %L', q.question, o.option);
      EXECUTE sql INTO count_value;
      IF count_value IS NULL THEN count_value := 0; END IF;

      result := jsonb_set(
        result, ARRAY[q.question],
        (
          result -> q.question
          || jsonb_build_object(
              'option', o.option,
              'count', count_value,
              'percent',
                CASE WHEN total_question_filtered = 0 THEN 0
                     ELSE round((count_value / total_question_filtered) * 100, 2)
                END,
              'total_responses', total_question_filtered,
              'avg_score', round(avg_score_question, 2)
            )
        )::jsonb,
        FALSE
      );
    END LOOP;
  END LOOP;

  -- ============================================================================
  -- ADICIONA KPIs E TOTAIS AO RESULTADO
  -- ============================================================================

  IF COALESCE(p_include_total, TRUE) THEN
    result := result || jsonb_build_object(
      'kpi_geral', round(kpi_geral, 2),
      'kpi_grupo_1', round(kpi_grupo_1, 2),
      'kpi_grupo_2', round(kpi_grupo_2, 2),
      'total_count_global', COALESCE(total_global, 0),
      'total_filtered_global', COALESCE(total_global_filtered, 0),
      'avg_score_global', round(avg_score_global, 2)
    );
  END IF;

  RETURN result;
END;
$$;


ALTER FUNCTION "public"."get_teacher_impact_survey_stats"("p_city" "text", "p_state" "text", "p_program" "text", "p_teacher" "text", "p_start_date" "date", "p_end_date" "date", "p_include_total" boolean) OWNER TO "postgres";


COMMENT ON FUNCTION "public"."get_teacher_impact_survey_stats"("p_city" "text", "p_state" "text", "p_program" "text", "p_teacher" "text", "p_start_date" "date", "p_end_date" "date", "p_include_total" boolean) IS 'Retorna estatísticas da pesquisa de impacto dos professores incluindo 3 KPIs:
1. KPI Geral: média de todas as 10 perguntas (escala 0-3)
2. KPI Grupo 1: média das 6 perguntas - sentir preparado, confiança, segurança, participação, materiais, integração (escala 0-3)
3. KPI Grupo 2: média das 4 perguntas restantes - adaptação, atividades musicais, engajamento, formações (escala 0-3)
Versão 3.0 - Escala 0-3 (Discordo totalmente=0, Discordo parcialmente=1, Concordo parcialmente=2, Concordo totalmente=3)';



CREATE OR REPLACE FUNCTION "public"."get_total_horas_aulas"("p_instrumento" "text" DEFAULT NULL::"text", "p_professor" "text" DEFAULT NULL::"text", "p_programa" "text" DEFAULT NULL::"text", "p_patrocinador" "text" DEFAULT NULL::"text", "p_turma" "text" DEFAULT NULL::"text", "p_ano" integer DEFAULT NULL::integer, "p_data_inicio" "date" DEFAULT NULL::"date", "p_data_fim" "date" DEFAULT NULL::"date") RETURNS "jsonb"
    LANGUAGE "plpgsql" STABLE
    AS $_$
BEGIN
  RETURN (
    SELECT jsonb_build_object(
      $q$total_horas$q$,    COALESCE(SUM(s.duration), 0),
      $q$att_rate_media$q$, ROUND(COALESCE(AVG(s.att_rate), 0)::numeric, 2)
    )
    FROM schedule s
    JOIN class c    ON c.unique_id = s.class_id
    JOIN programs p ON p.unique_id = c.program
    WHERE s.presenca_anotada = true
      AND (p_instrumento  IS NULL OR c.instrument_os ILIKE concat(chr(37), p_instrumento, chr(37)))
      AND (p_professor    IS NULL OR s.teacher_id    = p_professor)
      AND (p_programa     IS NULL OR p.unique_id     = p_programa)
      AND (p_turma        IS NULL OR c.unique_id     = p_turma)
      AND (p_ano          IS NULL OR EXTRACT(YEAR FROM s.date) = p_ano)
      AND (p_data_inicio  IS NULL OR s.date >= p_data_inicio)
      AND (p_data_fim     IS NULL OR s.date <= p_data_fim)
      AND (p_patrocinador IS NULL OR p.unique_id IN (
            SELECT program_id FROM program_patrocinadores WHERE sponsor_id = p_patrocinador
          ))
  );
END;
$_$;


ALTER FUNCTION "public"."get_total_horas_aulas"("p_instrumento" "text", "p_professor" "text", "p_programa" "text", "p_patrocinador" "text", "p_turma" "text", "p_ano" integer) OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."handle_update_student_age"() RETURNS "trigger"
    LANGUAGE "plpgsql"
    AS $$
begin
  -- Verifica se a data de nascimento (DOB) não é nula
  if new."DOB" is not null then
    -- Calcula a idade numérica
    new."Age_Number" := date_part('year', age(new."DOB"::date));
    -- Atualiza o campo de texto "Age" com o número convertido
    new."Age" := new."Age_Number"::text;
  else
    new."Age_Number" := null;
    new."Age" := null;
  end if;
  
  return new;
end;
$$;


ALTER FUNCTION "public"."handle_update_student_age"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."insert_rel_media_survey_monitoramento_sinta_som"("p_survey_unique_id" "text", "p_urls" "text"[]) RETURNS "void"
    LANGUAGE "sql"
    AS $$
  insert into public.rel_media_survey_monitoramento_sinta_som (survey_unique_id, url)
  select
    p_survey_unique_id,
    unnest(p_urls);
$$;


ALTER FUNCTION "public"."insert_rel_media_survey_monitoramento_sinta_som"("p_survey_unique_id" "text", "p_urls" "text"[]) OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."normalize_pavimentacao"() RETURNS "trigger"
    LANGUAGE "plpgsql"
    AS $$
BEGIN
  IF NEW."pavimentação" IS NOT NULL AND NEW."pavimentação" != '' THEN
    NEW."pavimentação" := TRIM(
      REGEXP_REPLACE(
        REPLACE(NEW."pavimentação", ',', ''),
        '\s+', ' ', 'g'  -- Substitui múltiplos espaços por um único
      )
    );
  END IF;
  
  RETURN NEW;
END;
$$;


ALTER FUNCTION "public"."normalize_pavimentacao"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."process_rendimento_beneficios"() RETURNS "trigger"
    LANGUAGE "plpgsql"
    AS $$
BEGIN
  -- Processar rendimentos/benefícios
  IF NEW."rendimentos_beneficios" IS NOT NULL 
     AND NEW."rendimentos_beneficios" != '' 
     AND NEW."rendimentos_beneficios" != 'null' THEN
    NEW."rendimento_beneficios_array" := (
      SELECT jsonb_agg(
        REPLACE(value::text, ',', '')
      )
      FROM jsonb_array_elements_text(NEW."rendimentos_beneficios"::jsonb)
    );
  ELSE
    NEW."rendimento_beneficios_array" := '[]'::jsonb;
  END IF;
  
  RETURN NEW;
END;
$$;


ALTER FUNCTION "public"."process_rendimento_beneficios"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."process_servicos_politicas"() RETURNS "trigger"
    LANGUAGE "plpgsql"
    AS $$
BEGIN
  -- Converter a coluna texto para JSONB array
  IF NEW."Serviços_politicas" IS NOT NULL 
     AND NEW."Serviços_politicas" != '' 
     AND NEW."Serviços_politicas" != 'null' THEN
    
    -- Converte para JSONB e remove texto entre parênteses
    NEW."servicos_politicas_array" := (
      SELECT jsonb_agg(
        TRIM(REGEXP_REPLACE(value::text, '\s*\([^)]*\)', '', 'g'))
      )
      FROM jsonb_array_elements_text(NEW."Serviços_politicas"::jsonb)
    );
  ELSE
    -- Se não houver dados, cria array vazio
    NEW."servicos_politicas_array" := '[]'::jsonb;
  END IF;
  
  RETURN NEW;
END;
$$;


ALTER FUNCTION "public"."process_servicos_politicas"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."rotate_wake_up"() RETURNS TABLE("id" bigint, "created_at" timestamp with time zone, "wake_up" boolean)
    LANGUAGE "plpgsql"
    AS $$
DECLARE
    oldest_record_id bigint;
BEGIN
    -- Seleciona o id mais antigo
    SELECT wake.id INTO oldest_record_id
    FROM public.wake_up_supabase AS wake
    ORDER BY wake.id
    LIMIT 1;

    -- Remove o registro mais antigo, caso exista
    IF oldest_record_id IS NOT NULL THEN
        DELETE FROM public.wake_up_supabase AS wake
        WHERE wake.id = oldest_record_id;
    END IF;

    -- Insere um novo registro wake_up = TRUE e retorna o novo resultado
    RETURN QUERY
    INSERT INTO public.wake_up_supabase (wake_up)
    VALUES (TRUE)
    RETURNING wake_up_supabase.id,
              wake_up_supabase.created_at,
              wake_up_supabase.wake_up;
END;
$$;


ALTER FUNCTION "public"."rotate_wake_up"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."set_modified_date"() RETURNS "trigger"
    LANGUAGE "plpgsql"
    AS $$
begin
  new.modified_date := now();
  return new;
end;
$$;


ALTER FUNCTION "public"."set_modified_date"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."students_with_birthday_on"("p_day" integer, "p_month" integer) RETURNS TABLE("unique id" "text", "First Name" "text", "fullname" "text", "DOB" "date", "age" integer)
    LANGUAGE "sql" STABLE
    AS $$
  SELECT
    s."unique id",
    s."First Name",
    s.fullname,
    s."DOB"::date AS "DOB",
    (DATE_PART('year', AGE(CURRENT_DATE, s."DOB"::date)))::int AS age
  FROM public."Students" s
  WHERE EXTRACT(day FROM s."DOB"::date) = p_day
    AND EXTRACT(month FROM s."DOB"::date) = p_month;
$$;


ALTER FUNCTION "public"."students_with_birthday_on"("p_day" integer, "p_month" integer) OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."update_modified_date"() RETURNS "trigger"
    LANGUAGE "plpgsql"
    AS $$
BEGIN
  NEW.modified_date = now();
  RETURN NEW;
END;
$$;


ALTER FUNCTION "public"."update_modified_date"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."update_student_attendance_rate"() RETURNS "trigger"
    LANGUAGE "plpgsql"
    AS $$
begin
  -- ✅ Mantém como numérico para facilitar ordenação e cálculos
  update "Students"
  set "Attendance Rate" = (
    select round(
      (count(case when status in ('present', 'justified_absence') then 1 end)::numeric 
       / nullif(count(*), 0)) * 100, 
      2
    )::text -- Converter para text apenas se o campo for text
    from attendance
    where student_id = NEW.student_id
  )
  where "unique id" = NEW.student_id;
  
  return NEW;
exception
  when others then
    raise warning 'Erro ao atualizar Attendance Rate do aluno %: %', NEW.student_id, sqlerrm;
    return NEW;
end;
$$;


ALTER FUNCTION "public"."update_student_attendance_rate"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."update_updated_at_column"() RETURNS "trigger"
    LANGUAGE "plpgsql"
    AS $$
BEGIN
  NEW.updated_at = now();
  RETURN NEW;
END;
$$;


ALTER FUNCTION "public"."update_updated_at_column"() OWNER TO "postgres";

SET default_tablespace = '';

SET default_table_access_method = "heap";


CREATE TABLE IF NOT EXISTS "public"."Customer Satisfaction Survey" (
    "1_sustentabilidade" "text",
    "2_Acesso_Formação_Musical" "text",
    "3_Impacto_Pessoal_Comunitário" "text",
    "4_Projeção_de_Futuro" "text",
    "5_Pergunta_aberta" "text",
    "Cidade" "text",
    "Estado" "text",
    "Eu_sou" "text",
    "Creation Date" timestamp without time zone,
    "Modified Date" timestamp without time zone,
    "Slug" "text",
    "Creator" "text",
    "unique id" "text" NOT NULL,
    "6_exposicao_arte" "text",
    "caravana" "text",
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL
);


ALTER TABLE "public"."Customer Satisfaction Survey" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."Customer Satisfaction Survey options" (
    "id" bigint NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "option" "text",
    "rank" smallint
);


ALTER TABLE "public"."Customer Satisfaction Survey options" OWNER TO "postgres";


ALTER TABLE "public"."Customer Satisfaction Survey options" ALTER COLUMN "id" ADD GENERATED BY DEFAULT AS IDENTITY (
    SEQUENCE NAME "public"."Customer Satisfaction Survey options_id_seq"
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);



CREATE TABLE IF NOT EXISTS "public"."Inscrições Treinamento" (
    "supabase_uuid" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "bubble_unique_id" "text" NOT NULL,
    "nome" "text" NOT NULL,
    "email" "text" NOT NULL,
    "cargo" "text",
    "tamanho_camisa" "text",
    "segmento" "text",
    "autoriza_uso_imagem" boolean DEFAULT false,
    "cidade" "text",
    "estado" "text",
    "patrocinador" "text",
    "treinamento" "text",
    "created_at" timestamp with time zone DEFAULT "now"()
);


ALTER TABLE "public"."Inscrições Treinamento" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."Parents" (
    "Address" "text",
    "Address City" "text",
    "Address State" "text",
    "Bairro" "text",
    "Best time to contact" "text",
    "Cell Phone" "text",
    "CEP" "text",
    "Cidade" "text",
    "complemento_endereco" "text",
    "comprovante_residencia" "text",
    "CPF" "text",
    "Email" "text",
    "First Name" "text",
    "Grau de parentesco" "text",
    "Home Phone" "text",
    "ID" bigint,
    "id_student_ibme" "text",
    "Language of preference" "text",
    "Last name" "text",
    "numero_endereco" "text",
    "Parent" "text",
    "Period of day" "text",
    "RG" "text",
    "rg ou cpf_img" "text",
    "rg ou cpf_img2" "text",
    "Rua" "text",
    "Signature_date" "text",
    "Signature_img" "text",
    "Student" "text",
    "UF" "text",
    "Zip Code" "text",
    "Creation Date" "text",
    "Modified Date" "text",
    "Slug" "text",
    "Creator" "text",
    "unique id" "text" NOT NULL,
    "Parent_type" smallint,
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL
);


ALTER TABLE "public"."Parents" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."Rate students" (
    "Attendance Rate" real,
    "Attendance_days" "text",
    "falta" smallint,
    "falta_justificada" smallint,
    "presença" smallint,
    "Program" "text",
    "Student" "text",
    "Total_Number_Classes" bigint,
    "Year" "text",
    "Creation Date" "date",
    "Modified Date" "date",
    "Slug" "text",
    "Creator" "text",
    "unique id" "text" NOT NULL,
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL
);


ALTER TABLE "public"."Rate students" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."Santander_Formularios" (
    "uuid" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "form_id" "text" NOT NULL,
    "q1" "text",
    "q2_a" "text",
    "q2_b" "text",
    "q2_c" "text",
    "q2_d" "text",
    "response_id" "text",
    "bubble_id" "text",
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL
);


ALTER TABLE "public"."Santander_Formularios" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."Sociocultural Profile" (
    "comunidade?" "text",
    "comunidade_nome" "text",
    "cursando" "text",
    "escolaridade mãe" "text",
    "escolaridade pai" "text",
    "faculdade" "text",
    "pavimentação" "text",
    "qtde de moradores" "text",
    "recebe do IBME" "text",
    "Região" "text",
    "renda familiar mensal" "text",
    "rendimentos_beneficios" "text",
    "Serviços_politicas" "text",
    "student" "text",
    "Área de risco" "text",
    "Creation Date" "text",
    "Modified Date" "text",
    "Slug" "text",
    "Creator" "text",
    "unique id" "text" NOT NULL,
    "type" "text",
    "servicos_politicas_array" "jsonb",
    "rendimento_beneficios_array" "jsonb",
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL
);


ALTER TABLE "public"."Sociocultural Profile" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."Students" (
    "Address" "text",
    "Admin" "text",
    "Age" "text",
    "Age_Number" smallint,
    "agencia" "text",
    "Allergies" "text",
    "Attendance Rate" "text",
    "Banco" "text",
    "Cartão CNPJ" "text",
    "Cell Phone" "text",
    "Certidão" "text",
    "Certidão_img" "text",
    "Certidão_numero" "text",
    "Classes" "text",
    "CNPJ" "text",
    "cnpj_tipo" "text",
    "conta_numero" "text",
    "conta_tipo" "text",
    "CPF" "text",
    "Date received" "text",
    "Dismissal Semester" "text",
    "DOB" "text",
    "Education Level" "text",
    "Email" "text",
    "Enrollment Form" "text",
    "Enrollment Semester" "text",
    "Ensemble" "text",
    "Estado" "text",
    "Ethnicity" "text",
    "Expelled" "text",
    "faltas" "text",
    "files" "text",
    "First Name" "text",
    "fullname" "text",
    "Gender" "text",
    "Going on to college" "text",
    "Grade" "text",
    "Graduation Rate" "text",
    "ID" bigint,
    "id_ibme" "text",
    "Instrument Number" "text",
    "Instrument_Enroll_Form" "text",
    "Inventory" "text",
    "Inventory Name" "text",
    "Language" "text",
    "Last Name" "text",
    "level" "text",
    "Living arangement" "text",
    "Main Teacher (old)" "text",
    "Medical Needs" "text",
    "municipio" "text",
    "Nome do Recebedor" "text",
    "Number of years" "text",
    "Other" "text",
    "Other activities" "text",
    "Parent 1" "text",
    "Parent 2" "text",
    "parent_academic_impact_survey" "text",
    "parent_satisfaction_survey" "text",
    "perfil_sociocultural" "text",
    "Photo" "text",
    "PIX" "text",
    "PIX?" "text",
    "Professores" "text",
    "Program_old" "text",
    "Programa" "text",
    "Re-enrollment status" "text",
    "Reason for dismissal" "text",
    "Retention Rate" "text",
    "RG" "text",
    "RG ou CPF_img" "text",
    "School" "text",
    "Signature (deleted)" "text",
    "Starting Date" "text",
    "Status" "text",
    "student_impact_survey" "text",
    "student_satisfaction_survey" "text",
    "Tamanho da Camisa" "text",
    "Timestamp" "text",
    "Turno" "text",
    "type" "text",
    "User" "text",
    "vínculo_empregatício" "text",
    "Zip Code" "text",
    "Creation Date" "text",
    "Modified Date" "text",
    "Slug" "text",
    "Creator" "text",
    "unique id" "text" NOT NULL,
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL
);


ALTER TABLE "public"."Students" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."Survey_Masterclass_Sinta_Som" (
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "cidade" "text",
    "estado" "text",
    "nome" "text",
    "qtd_alunos" numeric,
    "kp1_pergunta_1" "text",
    "kp1_pergunta_2" "text",
    "kp1_pergunta_3" "text",
    "kp1_pergunta_4" "text",
    "kp1_pergunta_5" "text",
    "kp1_pergunta_6" "text",
    "kp2_pergunta_1" "text",
    "kp2_pergunta_2" "text",
    "kp2_pergunta_3" "text",
    "kp2_pergunta_4" "text",
    "unique_id" "text" NOT NULL,
    "escolas_atuacao" "text",
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL
);


ALTER TABLE "public"."Survey_Masterclass_Sinta_Som" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."Teachers" (
    "Address" "text",
    "Admin" "text",
    "Age" bigint,
    "agencia" "text",
    "Att_rate" "text",
    "Att_rate_Teacher" "text",
    "Bairro" "text",
    "Banco" "text",
    "Bio" "text",
    "Cartão CNPJ" "text",
    "Cell Phone" "text",
    "CEP" "text",
    "Cidade" "text",
    "Classes" "text",
    "CNPJ" "text",
    "cnpj_tipo" "text",
    "Comments" "text",
    "complemento_endereco" "text",
    "comprovante_residencia" "text",
    "conta_numero" "text",
    "conta_tipo" "text",
    "CPF" "text",
    "cpf_photo" "text",
    "cv" "text",
    "DOB" "text",
    "Email" "text",
    "Estado Civil" "text",
    "Ethnicity" "text",
    "files" "text",
    "First Name" "text",
    "Formação" "text",
    "Gender" "text",
    "Highest Degree" "text",
    "Hourly Rate" "text",
    "ID" bigint,
    "instituição_ensino" "text",
    "Instrument" "text",
    "Last Name" "text",
    "Nome do Recebedor" "text",
    "nome_curso" "text",
    "numero_endereco" bigint,
    "Photo" "text",
    "PIX" "text",
    "PIX?" "text",
    "qtde_filhos" "text",
    "Resume" "text",
    "Ret_rate_Teacher" bigint,
    "RG" "text",
    "rg_data_expedicao" "text",
    "rg_emissor" "text",
    "rg_photo" "text",
    "rua" "text",
    "Signature_date" "text",
    "Signature_img" "text",
    "Status" "text",
    "status_escolaridade" "text",
    "Street Address, City and State" "text",
    "Student Survey" "text",
    "tamanho_camisa" "text",
    "UF" "text",
    "User" "text",
    "vínculo_empregatício" "text",
    "Zip Code" "text",
    "Creation Date" "date",
    "Modified Date" "date",
    "Slug" "text",
    "Creator" "text",
    "unique id" "text" NOT NULL,
    "Full name" "text",
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL
);


ALTER TABLE "public"."Teachers" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."app_logs" (
    "id" bigint NOT NULL,
    "timestamp" timestamp with time zone DEFAULT "now"(),
    "user_id" "text",
    "session_id" "text",
    "log_level" "text",
    "event_type" "text",
    "event_name" "text",
    "page_url" "text",
    "workflow_name" "text",
    "element_id" "text",
    "message" "text",
    "error_stack" "text",
    "context" "jsonb",
    "user_agent" "text",
    "ip_address" "inet",
    "app_version" "text",
    "environment" "text" DEFAULT 'production'::"text",
    CONSTRAINT "app_logs_log_level_check" CHECK (("log_level" = ANY (ARRAY['debug'::"text", 'info'::"text", 'warn'::"text", 'error'::"text", 'fatal'::"text"])))
);


ALTER TABLE "public"."app_logs" OWNER TO "postgres";


CREATE SEQUENCE IF NOT EXISTS "public"."app_logs_id_seq"
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER SEQUENCE "public"."app_logs_id_seq" OWNER TO "postgres";


ALTER SEQUENCE "public"."app_logs_id_seq" OWNED BY "public"."app_logs"."id";



CREATE TABLE IF NOT EXISTS "public"."attendance" (
    "id" bigint NOT NULL,
    "schedule_id" "text" NOT NULL,
    "student_id" "text" NOT NULL,
    "status" "public"."attendance_status" DEFAULT 'absent'::"public"."attendance_status" NOT NULL,
    "notes" "text",
    "created_at" timestamp with time zone DEFAULT "now"(),
    "updated_at" timestamp with time zone DEFAULT "now"(),
    "attendance_date" "date" NOT NULL
)
PARTITION BY RANGE ("attendance_date");


ALTER TABLE "public"."attendance" OWNER TO "postgres";


COMMENT ON TABLE "public"."attendance" IS 'Registro de presença dos alunos. Particionado por attendance_date para performance.';



CREATE TABLE IF NOT EXISTS "public"."attendance_2024" (
    "id" bigint NOT NULL,
    "schedule_id" "text" NOT NULL,
    "student_id" "text" NOT NULL,
    "status" "public"."attendance_status" DEFAULT 'absent'::"public"."attendance_status" NOT NULL,
    "notes" "text",
    "created_at" timestamp with time zone DEFAULT "now"(),
    "updated_at" timestamp with time zone DEFAULT "now"(),
    "attendance_date" "date" NOT NULL
);


ALTER TABLE "public"."attendance_2024" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."attendance_2025" (
    "id" bigint NOT NULL,
    "schedule_id" "text" NOT NULL,
    "student_id" "text" NOT NULL,
    "status" "public"."attendance_status" DEFAULT 'absent'::"public"."attendance_status" NOT NULL,
    "notes" "text",
    "created_at" timestamp with time zone DEFAULT "now"(),
    "updated_at" timestamp with time zone DEFAULT "now"(),
    "attendance_date" "date" NOT NULL
);


ALTER TABLE "public"."attendance_2025" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."attendance_2026" (
    "id" bigint NOT NULL,
    "schedule_id" "text" NOT NULL,
    "student_id" "text" NOT NULL,
    "status" "public"."attendance_status" DEFAULT 'absent'::"public"."attendance_status" NOT NULL,
    "notes" "text",
    "created_at" timestamp with time zone DEFAULT "now"(),
    "updated_at" timestamp with time zone DEFAULT "now"(),
    "attendance_date" "date" NOT NULL
);


ALTER TABLE "public"."attendance_2026" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."attendance_2027" (
    "id" bigint NOT NULL,
    "schedule_id" "text" NOT NULL,
    "student_id" "text" NOT NULL,
    "status" "public"."attendance_status" DEFAULT 'absent'::"public"."attendance_status" NOT NULL,
    "notes" "text",
    "created_at" timestamp with time zone DEFAULT "now"(),
    "updated_at" timestamp with time zone DEFAULT "now"(),
    "attendance_date" "date" NOT NULL
);


ALTER TABLE "public"."attendance_2027" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."attendance_default" (
    "id" bigint NOT NULL,
    "schedule_id" "text" NOT NULL,
    "student_id" "text" NOT NULL,
    "status" "public"."attendance_status" DEFAULT 'absent'::"public"."attendance_status" NOT NULL,
    "notes" "text",
    "created_at" timestamp with time zone DEFAULT "now"(),
    "updated_at" timestamp with time zone DEFAULT "now"(),
    "attendance_date" "date" NOT NULL
);


ALTER TABLE "public"."attendance_default" OWNER TO "postgres";


ALTER TABLE "public"."attendance" ALTER COLUMN "id" ADD GENERATED ALWAYS AS IDENTITY (
    SEQUENCE NAME "public"."attendance_id_seq"
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);



CREATE TABLE IF NOT EXISTS "public"."caravana_sinta_o_som" (
    "cidade" "text",
    "estado" "text",
    "patrocinador" "text",
    "unique_id" "text" NOT NULL,
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL
);


ALTER TABLE "public"."caravana_sinta_o_som" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."class" (
    "unique_id" "text" NOT NULL,
    "admin" "text" NOT NULL,
    "class_code" "text",
    "class_location" "text",
    "day_of_week" "text",
    "day_of_week_list" "text",
    "descricao" "text",
    "duration" numeric,
    "end_date" "date",
    "ensemble" "text",
    "instrument_inventory" "text",
    "instrument_os" "text",
    "max_students" smallint,
    "professores" "text",
    "program" "text",
    "retention_rate" "text",
    "start_date" "date",
    "start_time" time without time zone,
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL
);


ALTER TABLE "public"."class" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."funarate_avaliacao_responsaveis" (
    "acesso_cultura_q1" "text",
    "acesso_cultura_q2" "text",
    "desenvolvimento_pessoal_q1" numeric,
    "desenvolvimento_pessoal_q2" numeric,
    "desenvolvimento_pessoal_q3" numeric,
    "desenvolvimento_pessoal_q4" numeric,
    "desenvolvimento_pessoal_q5" numeric,
    "impacto_educacional_q1" "text",
    "impacto_educacional_q2" "text",
    "avalicao_atividades_q1" "text",
    "avalicao_atividades_q2" "text",
    "sugestão" "text",
    "depoimento" "text",
    "student" "text",
    "bubble_uuid" "text" NOT NULL,
    "uuid" "uuid"
);


ALTER TABLE "public"."funarate_avaliacao_responsaveis" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."funarte_avaliacao_aluno" (
    "unique_id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "bubble_unique_id" "text",
    "student" "text",
    "acesso_cultura_q1" "text",
    "acesso_cultura_q2" "text",
    "desenvolvimento_pessoal_q1" numeric,
    "desenvolvimento_pessoal_q2" numeric,
    "desenvolvimento_pessoal_q3" numeric,
    "desenvolvimento_pessoal_q4" numeric,
    "desenvolvimento_pessoal_q5" numeric,
    "impacto_educacional_q1" "text",
    "impacto_educacional_q2" "text",
    "avalicao_atividades_q1" "text",
    "avalicao_atividades_q2" "text",
    "sugestao" "text",
    "depoimento" "text",
    "created_at" timestamp with time zone DEFAULT "now"()
);


ALTER TABLE "public"."funarte_avaliacao_aluno" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."indicadores_ibme" (
    "unique_id" "text" NOT NULL,
    "created_date" timestamp with time zone,
    "modified_date" timestamp with time zone,
    "created_by" "text",
    "student" "text",
    "p1_q1_trabalho_atual" "text",
    "p1_q2_trab_impacto_ibme" "text",
    "p2_q1_oportunidade_internacional" "text",
    "p2_q2_impacto_oport_internacional" "text",
    "p3_q1_renda_familiar_num" numeric,
    "p3_q1_renda_familiar_txt" "text",
    "p3_q2_qtd_pessoas" integer,
    "p3_q4_impacto_bolsa_familia" numeric,
    "p3_q5_impacto_bolsa_per_capita" numeric,
    "p3_qt3_vlr_bolsa" numeric,
    "renda_per_capita_geral" numeric,
    "p4_q1_remuneracao_extra" "text",
    "p8_q1_curso_musica" "text",
    "ensino_medio" boolean,
    "ensino_superior" boolean,
    "nome_curso_superior" "text",
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL
);


ALTER TABLE "public"."indicadores_ibme" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."instrument_os" (
    "id" bigint NOT NULL,
    "english_name" "text" NOT NULL,
    "portuguese_name" "text" NOT NULL
);


ALTER TABLE "public"."instrument_os" OWNER TO "postgres";


CREATE SEQUENCE IF NOT EXISTS "public"."instrument_os_id_seq"
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER SEQUENCE "public"."instrument_os_id_seq" OWNER TO "postgres";


ALTER SEQUENCE "public"."instrument_os_id_seq" OWNED BY "public"."instrument_os"."id";



CREATE TABLE IF NOT EXISTS "public"."inventory" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "bubble_id" "text",
    "brand" "text",
    "codigo" "text",
    "model" "text",
    "serial_number" "text",
    "instrument" "text",
    "size" "text",
    "descricao" "text",
    "inventory_filter" "text",
    "condition" "public"."condition_status",
    "date_received" "date",
    "owner" "text",
    "issued_to" "text",
    "signed_term_date" "date",
    "parent_signature_url" "text",
    "photo_url" "text",
    "qr_img_url" "text",
    "qr_file_url" "text",
    "programa" "text",
    "school_campus" "text",
    "admin" "text",
    "creator" "text",
    "slug" "text",
    "created_date" timestamp with time zone DEFAULT "now"(),
    "modified_date" timestamp with time zone DEFAULT "now"()
);


ALTER TABLE "public"."inventory" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."parent_satisfaction_survey" (
    "unique_id" "text" NOT NULL,
    "student" "text" NOT NULL,
    "q1" "text",
    "q2" "text",
    "q3" "text",
    "q4" "text",
    "q5" "text",
    "q6" "text",
    "q7" "text",
    "q8" "text",
    "q9" "text",
    "q10" "text",
    "q11" "text",
    "q12" "text",
    "q13" "text",
    "q14" "text",
    "q15" "text",
    "q16" "text",
    "q17" "text",
    "q18" "text",
    "q19" "text",
    "q20" "text",
    "q21" "text",
    "q22" "text",
    "q23" "text",
    "score" numeric,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL
);


ALTER TABLE "public"."parent_satisfaction_survey" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."patrimonio" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "bubble_id" "text",
    "brand" "text",
    "code" "text",
    "condition" "public"."condition_status",
    "date_received" "date",
    "descricao" "text",
    "owner" "text",
    "patrimonio" "text",
    "programa" "text",
    "school_campus" "text",
    "admin" "text",
    "creator" "text",
    "slug" "text",
    "created_date" timestamp with time zone DEFAULT "now"(),
    "modified_date" timestamp with time zone DEFAULT "now"()
);


ALTER TABLE "public"."patrimonio" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."program_classes" (
    "unique_id" "text" NOT NULL,
    "program_id" "text" NOT NULL,
    "class_unique_id" "text" NOT NULL,
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL
);


ALTER TABLE "public"."program_classes" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."program_instruments" (
    "unique_id" "text" NOT NULL,
    "program_id" "text" NOT NULL,
    "instrument_os_id" bigint NOT NULL,
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL
);


ALTER TABLE "public"."program_instruments" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."program_patrocinadores" (
    "program_id" "text" NOT NULL,
    "sponsor_id" "text" NOT NULL,
    "unique_id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL
);


ALTER TABLE "public"."program_patrocinadores" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."program_teachers" (
    "unique_id" "text" NOT NULL,
    "program_id" "text" NOT NULL,
    "teacher_unique_id" "text" NOT NULL,
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL
);


ALTER TABLE "public"."program_teachers" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."programs" (
    "unique_id" "text" NOT NULL,
    "admin" "text" NOT NULL,
    "assistant" "text",
    "bairro" "text",
    "cep" "text",
    "cidade" "text",
    "complemento_endereco" "text",
    "description" "text",
    "key_searchable" "text",
    "location_address" "text",
    "numero_endereco" numeric,
    "program_name" "text",
    "ret_rate_program" numeric(5,2),
    "rua" "text",
    "uf" "text",
    "creator" "text",
    "modified_date" "date" DEFAULT CURRENT_DATE,
    "created_date" "date" DEFAULT CURRENT_DATE,
    "slug" "text",
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL
);


ALTER TABLE "public"."programs" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."rel_media_survey_monitoramento_sinta_som" (
    "id" bigint NOT NULL,
    "survey_unique_id" "text" NOT NULL,
    "url" "text"
);


ALTER TABLE "public"."rel_media_survey_monitoramento_sinta_som" OWNER TO "postgres";


ALTER TABLE "public"."rel_media_survey_monitoramento_sinta_som" ALTER COLUMN "id" ADD GENERATED ALWAYS AS IDENTITY (
    SEQUENCE NAME "public"."rel_media_survey_monitoramento_sinta_som_id_seq"
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);



CREATE TABLE IF NOT EXISTS "public"."relatorios_sinta_som" (
    "unique_id" "text" NOT NULL,
    "titulo" "text",
    "perfil_respondente" "text",
    "url" "text",
    "periodicidade" "text",
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "creator" "text",
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL
);


ALTER TABLE "public"."relatorios_sinta_som" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."schedule" (
    "admin" "text" NOT NULL,
    "att_rate" numeric(5,2),
    "date" "date" NOT NULL,
    "duration" numeric,
    "presenca_anotada" boolean DEFAULT false,
    "class_id" "text",
    "teacher_id" "text",
    "unique_id" "text" NOT NULL,
    "uuid" "uuid" DEFAULT "gen_random_uuid"() NOT NULL
);


ALTER TABLE "public"."schedule" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."sinta_o_som_survey_teacher" (
    "unique_id" "text" NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"(),
    "adaptacao_proposta" "text",
    "atividades_musicais" "text",
    "confianca" "text",
    "engajamento_alunos" "text",
    "formacoes" "text",
    "integracao_repertorio_atividades" "text",
    "materiais_didaticos" "text",
    "participacao" "text",
    "seguranca_jogos_musicais" "text",
    "sentir_preparado" "text",
    "teacher" "text",
    "programa" "text",
    "cidade" "text",
    "estado" "text",
    "qtd_alunos" numeric,
    "score" numeric,
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL
);


ALTER TABLE "public"."sinta_o_som_survey_teacher" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."sponsors" (
    "unique_id" "text" NOT NULL,
    "nome" "text" NOT NULL,
    "descricao" "text",
    "logo" "text",
    "creator" "text",
    "modified_date" "date" DEFAULT CURRENT_DATE,
    "created_date" "date" DEFAULT CURRENT_DATE,
    "slug" "text",
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL
);


ALTER TABLE "public"."sponsors" OWNER TO "postgres";


CREATE OR REPLACE VIEW "public"."student_full_profile" WITH ("security_invoker"='on') AS
 SELECT "s"."unique id" AS "student_unique_id",
    "p"."unique id" AS "sociocultural_profile_unique_id",
    "s"."Address",
    "s"."Admin",
    "s"."Age",
    "s"."Age_Number",
    "s"."agencia",
    "s"."Allergies",
    "s"."Attendance Rate",
    "s"."Banco",
    "s"."Cartão CNPJ",
    "s"."Cell Phone",
    "s"."Certidão",
    "s"."Certidão_img",
    "s"."Certidão_numero",
    "s"."Classes",
    "s"."CNPJ",
    "s"."cnpj_tipo",
    "s"."conta_numero",
    "s"."conta_tipo",
    "s"."CPF",
    "s"."Date received",
    "s"."Dismissal Semester",
    "s"."DOB",
    "s"."Education Level",
    "s"."Email",
    "s"."Enrollment Form",
    "s"."Enrollment Semester",
    "s"."Ensemble",
    "s"."Estado",
    "s"."Ethnicity",
    "s"."Expelled",
    "s"."faltas",
    "s"."files",
    "s"."First Name",
    "s"."fullname",
    "s"."Gender",
    "s"."Going on to college",
    "s"."Grade",
    "s"."Graduation Rate",
    "s"."ID",
    "s"."id_ibme",
    "s"."Instrument Number",
    "s"."Instrument_Enroll_Form",
    "s"."Inventory",
    "s"."Inventory Name",
    "s"."Language",
    "s"."Last Name",
    "s"."level",
    "s"."Living arangement",
    "s"."Main Teacher (old)",
    "s"."Medical Needs",
    "s"."municipio",
    "s"."Nome do Recebedor",
    "s"."Number of years",
    "s"."Other",
    "s"."Other activities",
    "s"."Parent 1",
    "s"."Parent 2",
    "s"."parent_academic_impact_survey",
    "s"."parent_satisfaction_survey",
    "s"."perfil_sociocultural",
    "s"."Photo",
    "s"."PIX",
    "s"."PIX?",
    "s"."Professores",
    "s"."Program_old",
    "s"."Programa",
    "s"."Re-enrollment status",
    "s"."Reason for dismissal",
    "s"."Retention Rate",
    "s"."RG",
    "s"."RG ou CPF_img",
    "s"."School",
    "s"."Signature (deleted)",
    "s"."Starting Date",
    "s"."Status",
    "s"."student_impact_survey",
    "s"."student_satisfaction_survey",
    "s"."Tamanho da Camisa",
    "s"."Timestamp",
    "s"."Turno",
    "s"."type",
    "s"."User",
    "s"."vínculo_empregatício",
    "s"."Zip Code",
    "p"."comunidade?",
    "p"."comunidade_nome",
    "p"."cursando",
    "p"."escolaridade mãe",
    "p"."escolaridade pai",
    "p"."faculdade",
    "p"."pavimentação",
    "p"."qtde de moradores",
    "p"."recebe do IBME",
    "p"."Região",
    "p"."renda familiar mensal",
    "p"."rendimentos_beneficios",
    "p"."Serviços_politicas",
    "p"."student",
    "p"."Área de risco"
   FROM ("public"."Students" "s"
     JOIN "public"."Sociocultural Profile" "p" ON (("s"."perfil_sociocultural" = "p"."unique id")));


ALTER VIEW "public"."student_full_profile" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."student_impact_survey" (
    "unique_id" "text" NOT NULL,
    "q1" "text",
    "q2" "text",
    "q3" "text",
    "q4" "text",
    "q5" "text",
    "q6" "text",
    "q7" "text",
    "q8" "text",
    "q9" "text",
    "score" numeric,
    "student" "text" NOT NULL,
    "created_date" timestamp with time zone DEFAULT "now"() NOT NULL,
    "modified_date" timestamp with time zone DEFAULT "now"() NOT NULL,
    "id" bigint NOT NULL
);


ALTER TABLE "public"."student_impact_survey" OWNER TO "postgres";


ALTER TABLE "public"."student_impact_survey" ALTER COLUMN "id" ADD GENERATED ALWAYS AS IDENTITY (
    SEQUENCE NAME "public"."student_impact_survey_id_seq"
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);



CREATE TABLE IF NOT EXISTS "public"."student_satisfaction_survey" (
    "unique_id" "text" NOT NULL,
    "to tell Harmony Project" "text",
    "could this teacher do better" "text",
    "enjoy working with this teacher" "text",
    "feel comfortable asking" "text",
    "language" "text",
    "on time" "text",
    "organized" "text",
    "patient" "text",
    "respect the teacher" "text",
    "score" numeric,
    "something about this teacher" "text",
    "student" "text" NOT NULL,
    "students fairly" "text",
    "teacher" "text",
    "teacher challenges_inspires" "text",
    "teacher during class" "text",
    "teacher is a good role model" "text",
    "teacher is an expert" "text",
    "teacher next year" "text",
    "created_date" timestamp with time zone DEFAULT "now"(),
    "modified_date" timestamp with time zone DEFAULT "now"(),
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL
);


ALTER TABLE "public"."student_satisfaction_survey" OWNER TO "postgres";


CREATE OR REPLACE VIEW "public"."student_teachers_connection" AS
 SELECT "s"."fullname",
    "s"."DOB" AS "dob",
    "s"."unique id" AS "unique_id",
    "string_agg"(DISTINCT "c"."unique_id", ', '::"text" ORDER BY "c"."unique_id") AS "class_ids",
    "string_agg"(DISTINCT "t"."unique id", ', '::"text" ORDER BY "t"."unique id") AS "teacher_ids"
   FROM (("public"."Students" "s"
     JOIN "public"."class" "c" ON (("s"."Classes" ~~ (('%'::"text" || "c"."unique_id") || '%'::"text"))))
     JOIN "public"."Teachers" "t" ON (("c"."professores" ~~ (('%'::"text" || "t"."unique id") || '%'::"text"))))
  WHERE ("s"."Status" = 'Ativo'::"text")
  GROUP BY "s"."unique id", "s"."fullname", "s"."DOB"
  ORDER BY "s"."fullname";


ALTER VIEW "public"."student_teachers_connection" OWNER TO "postgres";


CREATE OR REPLACE VIEW "public"."students_dob" AS
 SELECT "fullname",
    "DOB",
    "unique id"
   FROM "public"."Students"
  ORDER BY "fullname" DESC;


ALTER VIEW "public"."students_dob" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."students_invite_code" (
    "invite_code" "text" DEFAULT "substr"("md5"(("gen_random_uuid"())::"text"), 1, 8) NOT NULL,
    "student" "text",
    "created_date" timestamp with time zone DEFAULT "now"(),
    "step" smallint,
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL
);


ALTER TABLE "public"."students_invite_code" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."survey_monitoramento_sinta_som" (
    "unique_id" "text" NOT NULL,
    "aplicacao_da_metodologia" "text",
    "cidade" "text",
    "class" "text" NOT NULL,
    "conteudo_sustentabilidade" "text",
    "conteudo_musical" "text",
    "intervalo" "daterange",
    "necessidades_desafios" "text",
    "nivel_entusiasmo" "text",
    "observacoes" "text",
    "program" "text",
    "teacher" "text",
    "total_alunos" numeric,
    "uf" "text",
    "created_date" timestamp with time zone DEFAULT "now"(),
    "modified_date" timestamp with time zone DEFAULT "now"(),
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL
);


ALTER TABLE "public"."survey_monitoramento_sinta_som" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."survey_sinta_o_som_aluno" (
    "unique_id" "text" NOT NULL,
    "colabora_com_colegas" "text",
    "cultura_da_regiao" "text",
    "curiosidade_por_musica" "text",
    "empatia_com_colegas" "text",
    "entusiasmo" "text",
    "expressar_em_publico" "text",
    "interesse_manifetacoes" "text",
    "interesse_tema_div_cultural" "text",
    "liderança" "text",
    "participa_atividades_culturais" "text",
    "persistencia" "text",
    "score" numeric,
    "created_date" timestamp with time zone DEFAULT "now"(),
    "modified_date" timestamp with time zone DEFAULT "now"(),
    "class" "text",
    "program" "text",
    "cidade" "text",
    "estado" "text",
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL
);


ALTER TABLE "public"."survey_sinta_o_som_aluno" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."survey_statements" (
    "id" bigint NOT NULL,
    "q_num" "text" NOT NULL,
    "statement" "text" NOT NULL,
    "table_name" "text" NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL
);


ALTER TABLE "public"."survey_statements" OWNER TO "postgres";


ALTER TABLE "public"."survey_statements" ALTER COLUMN "id" ADD GENERATED ALWAYS AS IDENTITY (
    SEQUENCE NAME "public"."survey_statements_id_seq"
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);



CREATE TABLE IF NOT EXISTS "public"."teacher_impact_survey" (
    "unique_id" "text" NOT NULL,
    "adaptacao da proposta com realidade" "text",
    "atividades musicais" "text",
    "cidade" "text",
    "confianca" "text",
    "engajamento dos alunos" "text",
    "estado" "text",
    "formacoes" "text",
    "integracao repertorio e atividades" "text",
    "materiais didaticos" "text",
    "participacao" "text",
    "programa" "text",
    "qtd de alunos" numeric,
    "score" numeric,
    "seguranca com jogos musicais" "text" NOT NULL,
    "sentir se preparado" "text",
    "created_date" timestamp with time zone DEFAULT "now"(),
    "modified_date" timestamp with time zone DEFAULT "now"(),
    "teacher" "text",
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL
);


ALTER TABLE "public"."teacher_impact_survey" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."wake_up_supabase" (
    "id" bigint NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "wake_up" boolean
);


ALTER TABLE "public"."wake_up_supabase" OWNER TO "postgres";


ALTER TABLE "public"."wake_up_supabase" ALTER COLUMN "id" ADD GENERATED BY DEFAULT AS IDENTITY (
    SEQUENCE NAME "public"."wake_up_supabase_id_seq"
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);



ALTER TABLE ONLY "public"."attendance" ATTACH PARTITION "public"."attendance_2024" FOR VALUES FROM ('2024-01-01') TO ('2025-01-01');



ALTER TABLE ONLY "public"."attendance" ATTACH PARTITION "public"."attendance_2025" FOR VALUES FROM ('2025-01-01') TO ('2026-01-01');



ALTER TABLE ONLY "public"."attendance" ATTACH PARTITION "public"."attendance_2026" FOR VALUES FROM ('2026-01-01') TO ('2027-01-01');



ALTER TABLE ONLY "public"."attendance" ATTACH PARTITION "public"."attendance_2027" FOR VALUES FROM ('2027-01-01') TO ('2028-01-01');



ALTER TABLE ONLY "public"."attendance" ATTACH PARTITION "public"."attendance_default" DEFAULT;



ALTER TABLE ONLY "public"."app_logs" ALTER COLUMN "id" SET DEFAULT "nextval"('"public"."app_logs_id_seq"'::"regclass");



ALTER TABLE ONLY "public"."instrument_os" ALTER COLUMN "id" SET DEFAULT "nextval"('"public"."instrument_os_id_seq"'::"regclass");



ALTER TABLE ONLY "public"."Customer Satisfaction Survey options"
    ADD CONSTRAINT "Customer Satisfaction Survey options_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."Customer Satisfaction Survey"
    ADD CONSTRAINT "Customer Satisfaction Survey_pkey" PRIMARY KEY ("unique id");



ALTER TABLE ONLY "public"."Inscrições Treinamento"
    ADD CONSTRAINT "Inscrições Treinamento_pkey" PRIMARY KEY ("supabase_uuid");



ALTER TABLE ONLY "public"."Parents"
    ADD CONSTRAINT "Parents_pkey" PRIMARY KEY ("unique id");



ALTER TABLE ONLY "public"."Rate students"
    ADD CONSTRAINT "Rate students_pkey" PRIMARY KEY ("unique id");



ALTER TABLE ONLY "public"."relatorios_sinta_som"
    ADD CONSTRAINT "Relatórios sinta o som_pkey" PRIMARY KEY ("unique_id");



ALTER TABLE ONLY "public"."Santander_Formularios"
    ADD CONSTRAINT "Santander_Formularios_pkey" PRIMARY KEY ("uuid");



ALTER TABLE ONLY "public"."Sociocultural Profile"
    ADD CONSTRAINT "Sociocultural Profile_pkey" PRIMARY KEY ("unique id");



ALTER TABLE ONLY "public"."Students"
    ADD CONSTRAINT "Students_pkey" PRIMARY KEY ("unique id");



ALTER TABLE ONLY "public"."Survey_Masterclass_Sinta_Som"
    ADD CONSTRAINT "Survey_Masterclass_Sinta_Som_pkey" PRIMARY KEY ("unique_id");



ALTER TABLE ONLY "public"."Teachers"
    ADD CONSTRAINT "Teachers_pkey" PRIMARY KEY ("unique id");



ALTER TABLE ONLY "public"."app_logs"
    ADD CONSTRAINT "app_logs_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."attendance"
    ADD CONSTRAINT "attendance_pkey" PRIMARY KEY ("id", "attendance_date");



ALTER TABLE ONLY "public"."attendance_2024"
    ADD CONSTRAINT "attendance_2024_pkey" PRIMARY KEY ("id", "attendance_date");



ALTER TABLE ONLY "public"."attendance"
    ADD CONSTRAINT "attendance_unique_student_per_schedule_date" UNIQUE ("schedule_id", "student_id", "attendance_date");



COMMENT ON CONSTRAINT "attendance_unique_student_per_schedule_date" ON "public"."attendance" IS 'Garante que um aluno só pode ter uma presença por aula/dia.';



ALTER TABLE ONLY "public"."attendance_2024"
    ADD CONSTRAINT "attendance_2024_schedule_id_student_id_attendance_date_key" UNIQUE ("schedule_id", "student_id", "attendance_date");



ALTER TABLE ONLY "public"."attendance_2025"
    ADD CONSTRAINT "attendance_2025_pkey" PRIMARY KEY ("id", "attendance_date");



ALTER TABLE ONLY "public"."attendance_2025"
    ADD CONSTRAINT "attendance_2025_schedule_id_student_id_attendance_date_key" UNIQUE ("schedule_id", "student_id", "attendance_date");



ALTER TABLE ONLY "public"."attendance_2026"
    ADD CONSTRAINT "attendance_2026_pkey" PRIMARY KEY ("id", "attendance_date");



ALTER TABLE ONLY "public"."attendance_2026"
    ADD CONSTRAINT "attendance_2026_schedule_id_student_id_attendance_date_key" UNIQUE ("schedule_id", "student_id", "attendance_date");



ALTER TABLE ONLY "public"."attendance_2027"
    ADD CONSTRAINT "attendance_2027_pkey" PRIMARY KEY ("id", "attendance_date");



ALTER TABLE ONLY "public"."attendance_2027"
    ADD CONSTRAINT "attendance_2027_schedule_id_student_id_attendance_date_key" UNIQUE ("schedule_id", "student_id", "attendance_date");



ALTER TABLE ONLY "public"."attendance_default"
    ADD CONSTRAINT "attendance_default_pkey" PRIMARY KEY ("id", "attendance_date");



ALTER TABLE ONLY "public"."attendance_default"
    ADD CONSTRAINT "attendance_default_schedule_id_student_id_attendance_date_key" UNIQUE ("schedule_id", "student_id", "attendance_date");



ALTER TABLE ONLY "public"."caravana_sinta_o_som"
    ADD CONSTRAINT "caravana_sinta_o_som_pkey" PRIMARY KEY ("unique_id");



ALTER TABLE ONLY "public"."class"
    ADD CONSTRAINT "class_pkey" PRIMARY KEY ("unique_id");



ALTER TABLE ONLY "public"."funarate_avaliacao_responsaveis"
    ADD CONSTRAINT "funarate_avaliacao_responsaveis_pkey" PRIMARY KEY ("bubble_uuid");



ALTER TABLE ONLY "public"."funarte_avaliacao_aluno"
    ADD CONSTRAINT "funarte_avaliacao_aluno_pkey" PRIMARY KEY ("unique_id");



ALTER TABLE ONLY "public"."indicadores_ibme"
    ADD CONSTRAINT "indicadores_ibme_pkey" PRIMARY KEY ("unique_id");



ALTER TABLE ONLY "public"."instrument_os"
    ADD CONSTRAINT "instrument_os_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."inventory"
    ADD CONSTRAINT "inventory_bubble_id_key" UNIQUE ("bubble_id");



ALTER TABLE ONLY "public"."inventory"
    ADD CONSTRAINT "inventory_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."parent_satisfaction_survey"
    ADD CONSTRAINT "parent_satisfaction_survey_pkey" PRIMARY KEY ("unique_id");



ALTER TABLE ONLY "public"."patrimonio"
    ADD CONSTRAINT "patrimonio_bubble_id_key" UNIQUE ("bubble_id");



ALTER TABLE ONLY "public"."patrimonio"
    ADD CONSTRAINT "patrimonio_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."program_classes"
    ADD CONSTRAINT "program_classes_pkey" PRIMARY KEY ("unique_id");



ALTER TABLE ONLY "public"."program_instruments"
    ADD CONSTRAINT "program_instruments_pkey" PRIMARY KEY ("unique_id");



ALTER TABLE ONLY "public"."program_patrocinadores"
    ADD CONSTRAINT "program_patrocinadores_pkey" PRIMARY KEY ("unique_id");



ALTER TABLE ONLY "public"."program_teachers"
    ADD CONSTRAINT "program_teachers_pkey" PRIMARY KEY ("unique_id");



ALTER TABLE ONLY "public"."programs"
    ADD CONSTRAINT "programs_pkey" PRIMARY KEY ("unique_id");



ALTER TABLE ONLY "public"."rel_media_survey_monitoramento_sinta_som"
    ADD CONSTRAINT "rel_media_survey_monitoramento_sinta_som_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."schedule"
    ADD CONSTRAINT "schedule_bubble_unique_id_key" UNIQUE ("unique_id");



ALTER TABLE ONLY "public"."schedule"
    ADD CONSTRAINT "schedule_pkey" PRIMARY KEY ("unique_id");



ALTER TABLE ONLY "public"."sinta_o_som_survey_teacher"
    ADD CONSTRAINT "sinta_o_som_survey_teacher_pkey" PRIMARY KEY ("unique_id");



ALTER TABLE ONLY "public"."sponsors"
    ADD CONSTRAINT "sponsors_pkey" PRIMARY KEY ("unique_id");



ALTER TABLE ONLY "public"."student_impact_survey"
    ADD CONSTRAINT "student_impact_survey_pkey" PRIMARY KEY ("unique_id");



ALTER TABLE ONLY "public"."student_satisfaction_survey"
    ADD CONSTRAINT "student_satisfaction_survey_pkey" PRIMARY KEY ("unique_id");



ALTER TABLE ONLY "public"."students_invite_code"
    ADD CONSTRAINT "students_invite_code_pkey" PRIMARY KEY ("invite_code");



ALTER TABLE ONLY "public"."survey_monitoramento_sinta_som"
    ADD CONSTRAINT "survey_monitoramento_sinta_som_pkey" PRIMARY KEY ("unique_id");



ALTER TABLE ONLY "public"."survey_sinta_o_som_aluno"
    ADD CONSTRAINT "survey_sinta_o_som_aluno_pkey" PRIMARY KEY ("unique_id");



ALTER TABLE ONLY "public"."survey_statements"
    ADD CONSTRAINT "survey_statements_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."teacher_impact_survey"
    ADD CONSTRAINT "teacher_impact_survey_pkey" PRIMARY KEY ("unique_id");



ALTER TABLE ONLY "public"."wake_up_supabase"
    ADD CONSTRAINT "wake_up_supabase_pkey" PRIMARY KEY ("id");



CREATE INDEX "idx_attendance_schedule" ON ONLY "public"."attendance" USING "btree" ("schedule_id");



CREATE INDEX "attendance_2024_schedule_id_idx" ON "public"."attendance_2024" USING "btree" ("schedule_id");



CREATE INDEX "idx_attendance_status_date" ON ONLY "public"."attendance" USING "btree" ("status", "attendance_date");



CREATE INDEX "attendance_2024_status_attendance_date_idx" ON "public"."attendance_2024" USING "btree" ("status", "attendance_date");



CREATE INDEX "idx_attendance_student_date" ON ONLY "public"."attendance" USING "btree" ("student_id", "attendance_date");



CREATE INDEX "attendance_2024_student_id_attendance_date_idx" ON "public"."attendance_2024" USING "btree" ("student_id", "attendance_date");



CREATE INDEX "attendance_2025_schedule_id_idx" ON "public"."attendance_2025" USING "btree" ("schedule_id");



CREATE INDEX "attendance_2025_status_attendance_date_idx" ON "public"."attendance_2025" USING "btree" ("status", "attendance_date");



CREATE INDEX "attendance_2025_student_id_attendance_date_idx" ON "public"."attendance_2025" USING "btree" ("student_id", "attendance_date");



CREATE INDEX "attendance_2026_schedule_id_idx" ON "public"."attendance_2026" USING "btree" ("schedule_id");



CREATE INDEX "attendance_2026_status_attendance_date_idx" ON "public"."attendance_2026" USING "btree" ("status", "attendance_date");



CREATE INDEX "attendance_2026_student_id_attendance_date_idx" ON "public"."attendance_2026" USING "btree" ("student_id", "attendance_date");



CREATE INDEX "attendance_2027_schedule_id_idx" ON "public"."attendance_2027" USING "btree" ("schedule_id");



CREATE INDEX "attendance_2027_status_attendance_date_idx" ON "public"."attendance_2027" USING "btree" ("status", "attendance_date");



CREATE INDEX "attendance_2027_student_id_attendance_date_idx" ON "public"."attendance_2027" USING "btree" ("student_id", "attendance_date");



CREATE INDEX "attendance_default_schedule_id_idx" ON "public"."attendance_default" USING "btree" ("schedule_id");



CREATE INDEX "attendance_default_status_attendance_date_idx" ON "public"."attendance_default" USING "btree" ("status", "attendance_date");



CREATE INDEX "attendance_default_student_id_attendance_date_idx" ON "public"."attendance_default" USING "btree" ("student_id", "attendance_date");



CREATE UNIQUE INDEX "caravana_sinta_o_som_id_key" ON "public"."caravana_sinta_o_som" USING "btree" ("id");



CREATE UNIQUE INDEX "class_id_key" ON "public"."class" USING "btree" ("id");



CREATE UNIQUE INDEX "customer_satisfaction_survey_id_key" ON "public"."Customer Satisfaction Survey" USING "btree" ("id");



CREATE INDEX "idx_customer_satisfaction_caravana" ON "public"."Customer Satisfaction Survey" USING "btree" ("caravana");



CREATE INDEX "idx_inventory_bubble_id" ON "public"."inventory" USING "btree" ("bubble_id");



CREATE INDEX "idx_inventory_condition" ON "public"."inventory" USING "btree" ("condition");



CREATE INDEX "idx_inventory_instrument" ON "public"."inventory" USING "btree" ("instrument");



CREATE INDEX "idx_inventory_issued_to" ON "public"."inventory" USING "btree" ("issued_to");



CREATE INDEX "idx_inventory_programa" ON "public"."inventory" USING "btree" ("programa");



CREATE INDEX "idx_logs_event_type" ON "public"."app_logs" USING "btree" ("event_type");



CREATE INDEX "idx_logs_level" ON "public"."app_logs" USING "btree" ("log_level");



CREATE INDEX "idx_logs_session" ON "public"."app_logs" USING "btree" ("session_id");



CREATE INDEX "idx_logs_timestamp" ON "public"."app_logs" USING "btree" ("timestamp" DESC);



CREATE INDEX "idx_logs_user_id" ON "public"."app_logs" USING "btree" ("user_id");



CREATE INDEX "idx_patrimonio_bubble_id" ON "public"."patrimonio" USING "btree" ("bubble_id");



CREATE INDEX "idx_patrimonio_condition" ON "public"."patrimonio" USING "btree" ("condition");



CREATE INDEX "idx_patrimonio_programa" ON "public"."patrimonio" USING "btree" ("programa");



CREATE INDEX "idx_program_classes_class_id" ON "public"."program_classes" USING "btree" ("class_unique_id");



CREATE INDEX "idx_program_classes_program_id" ON "public"."program_classes" USING "btree" ("program_id");



CREATE INDEX "idx_program_instruments_instrument_id" ON "public"."program_instruments" USING "btree" ("instrument_os_id");



CREATE INDEX "idx_program_instruments_program_id" ON "public"."program_instruments" USING "btree" ("program_id");



CREATE INDEX "idx_program_patrocinadores_program_id" ON "public"."program_patrocinadores" USING "btree" ("program_id");



CREATE INDEX "idx_program_patrocinadores_sponsor_id" ON "public"."program_patrocinadores" USING "btree" ("sponsor_id");



CREATE INDEX "idx_program_teachers_program_id" ON "public"."program_teachers" USING "btree" ("program_id");



CREATE INDEX "idx_program_teachers_teacher_id" ON "public"."program_teachers" USING "btree" ("teacher_unique_id");



CREATE UNIQUE INDEX "indicadores_ibme_id_key" ON "public"."indicadores_ibme" USING "btree" ("id");



CREATE UNIQUE INDEX "parent_satisfaction_survey_id_key" ON "public"."parent_satisfaction_survey" USING "btree" ("id");



CREATE INDEX "parent_satisfaction_survey_student_idx" ON "public"."parent_satisfaction_survey" USING "btree" ("student");



CREATE UNIQUE INDEX "parents_id_key" ON "public"."Parents" USING "btree" ("id");



CREATE UNIQUE INDEX "program_classes_id_key" ON "public"."program_classes" USING "btree" ("id");



CREATE UNIQUE INDEX "program_instruments_id_key" ON "public"."program_instruments" USING "btree" ("id");



CREATE UNIQUE INDEX "program_teachers_id_key" ON "public"."program_teachers" USING "btree" ("id");



CREATE UNIQUE INDEX "programs_id_key" ON "public"."programs" USING "btree" ("id");



CREATE UNIQUE INDEX "rate_students_id_key" ON "public"."Rate students" USING "btree" ("id");



CREATE UNIQUE INDEX "relatorios_sinta_som_id_key" ON "public"."relatorios_sinta_som" USING "btree" ("id");



CREATE UNIQUE INDEX "schedule_uuid_key" ON "public"."schedule" USING "btree" ("uuid");



CREATE UNIQUE INDEX "sinta_o_som_survey_teacher_id_key" ON "public"."sinta_o_som_survey_teacher" USING "btree" ("id");



CREATE UNIQUE INDEX "sociocultural_profile_id_key" ON "public"."Sociocultural Profile" USING "btree" ("id");



CREATE UNIQUE INDEX "sponsors_id_key" ON "public"."sponsors" USING "btree" ("id");



CREATE INDEX "student_impact_survey_id_idx" ON "public"."student_impact_survey" USING "btree" ("id");



CREATE INDEX "student_impact_survey_student_idx" ON "public"."student_impact_survey" USING "btree" ("student");



CREATE UNIQUE INDEX "student_satisfaction_survey_id_key" ON "public"."student_satisfaction_survey" USING "btree" ("id");



CREATE UNIQUE INDEX "students_id_key" ON "public"."Students" USING "btree" ("id");



CREATE UNIQUE INDEX "students_invite_code_id_key" ON "public"."students_invite_code" USING "btree" ("id");



CREATE UNIQUE INDEX "survey_masterclass_sinta_som_id_key" ON "public"."Survey_Masterclass_Sinta_Som" USING "btree" ("id");



CREATE UNIQUE INDEX "survey_monitoramento_sinta_som_id_key" ON "public"."survey_monitoramento_sinta_som" USING "btree" ("id");



CREATE UNIQUE INDEX "survey_sinta_o_som_aluno_id_key" ON "public"."survey_sinta_o_som_aluno" USING "btree" ("id");



CREATE INDEX "survey_statements_table_q_idx" ON "public"."survey_statements" USING "btree" ("table_name", "q_num");



CREATE UNIQUE INDEX "survey_statements_table_q_unique" ON "public"."survey_statements" USING "btree" ("table_name", "q_num");



CREATE UNIQUE INDEX "teacher_impact_survey_id_key" ON "public"."teacher_impact_survey" USING "btree" ("id");



CREATE UNIQUE INDEX "teachers_id_key" ON "public"."Teachers" USING "btree" ("id");



ALTER INDEX "public"."attendance_pkey" ATTACH PARTITION "public"."attendance_2024_pkey";



ALTER INDEX "public"."idx_attendance_schedule" ATTACH PARTITION "public"."attendance_2024_schedule_id_idx";



ALTER INDEX "public"."attendance_unique_student_per_schedule_date" ATTACH PARTITION "public"."attendance_2024_schedule_id_student_id_attendance_date_key";



ALTER INDEX "public"."idx_attendance_status_date" ATTACH PARTITION "public"."attendance_2024_status_attendance_date_idx";



ALTER INDEX "public"."idx_attendance_student_date" ATTACH PARTITION "public"."attendance_2024_student_id_attendance_date_idx";



ALTER INDEX "public"."attendance_pkey" ATTACH PARTITION "public"."attendance_2025_pkey";



ALTER INDEX "public"."idx_attendance_schedule" ATTACH PARTITION "public"."attendance_2025_schedule_id_idx";



ALTER INDEX "public"."attendance_unique_student_per_schedule_date" ATTACH PARTITION "public"."attendance_2025_schedule_id_student_id_attendance_date_key";



ALTER INDEX "public"."idx_attendance_status_date" ATTACH PARTITION "public"."attendance_2025_status_attendance_date_idx";



ALTER INDEX "public"."idx_attendance_student_date" ATTACH PARTITION "public"."attendance_2025_student_id_attendance_date_idx";



ALTER INDEX "public"."attendance_pkey" ATTACH PARTITION "public"."attendance_2026_pkey";



ALTER INDEX "public"."idx_attendance_schedule" ATTACH PARTITION "public"."attendance_2026_schedule_id_idx";



ALTER INDEX "public"."attendance_unique_student_per_schedule_date" ATTACH PARTITION "public"."attendance_2026_schedule_id_student_id_attendance_date_key";



ALTER INDEX "public"."idx_attendance_status_date" ATTACH PARTITION "public"."attendance_2026_status_attendance_date_idx";



ALTER INDEX "public"."idx_attendance_student_date" ATTACH PARTITION "public"."attendance_2026_student_id_attendance_date_idx";



ALTER INDEX "public"."attendance_pkey" ATTACH PARTITION "public"."attendance_2027_pkey";



ALTER INDEX "public"."idx_attendance_schedule" ATTACH PARTITION "public"."attendance_2027_schedule_id_idx";



ALTER INDEX "public"."attendance_unique_student_per_schedule_date" ATTACH PARTITION "public"."attendance_2027_schedule_id_student_id_attendance_date_key";



ALTER INDEX "public"."idx_attendance_status_date" ATTACH PARTITION "public"."attendance_2027_status_attendance_date_idx";



ALTER INDEX "public"."idx_attendance_student_date" ATTACH PARTITION "public"."attendance_2027_student_id_attendance_date_idx";



ALTER INDEX "public"."attendance_pkey" ATTACH PARTITION "public"."attendance_default_pkey";



ALTER INDEX "public"."idx_attendance_schedule" ATTACH PARTITION "public"."attendance_default_schedule_id_idx";



ALTER INDEX "public"."attendance_unique_student_per_schedule_date" ATTACH PARTITION "public"."attendance_default_schedule_id_student_id_attendance_date_key";



ALTER INDEX "public"."idx_attendance_status_date" ATTACH PARTITION "public"."attendance_default_status_attendance_date_idx";



ALTER INDEX "public"."idx_attendance_student_date" ATTACH PARTITION "public"."attendance_default_student_id_attendance_date_idx";



CREATE OR REPLACE TRIGGER "inventory_modified_date" BEFORE UPDATE ON "public"."inventory" FOR EACH ROW EXECUTE FUNCTION "public"."update_modified_date"();



CREATE OR REPLACE TRIGGER "patrimonio_modified_date" BEFORE UPDATE ON "public"."patrimonio" FOR EACH ROW EXECUTE FUNCTION "public"."update_modified_date"();



CREATE OR REPLACE TRIGGER "trg_check_attendance_date" BEFORE INSERT OR UPDATE ON "public"."attendance" FOR EACH ROW EXECUTE FUNCTION "public"."check_attendance_date_matches_schedule"();



CREATE OR REPLACE TRIGGER "trg_create_attendance_records" AFTER INSERT ON "public"."schedule" FOR EACH ROW EXECUTE FUNCTION "public"."create_attendance_records"();



CREATE OR REPLACE TRIGGER "trg_student_impact_survey_modified" BEFORE UPDATE ON "public"."student_impact_survey" FOR EACH ROW EXECUTE FUNCTION "public"."set_modified_date"();



CREATE OR REPLACE TRIGGER "trg_update_attendance_timestamp" BEFORE UPDATE ON "public"."attendance" FOR EACH ROW EXECUTE FUNCTION "public"."update_updated_at_column"();



CREATE OR REPLACE TRIGGER "trigger_process_rendimento_beneficios" BEFORE INSERT OR UPDATE ON "public"."Sociocultural Profile" FOR EACH ROW EXECUTE FUNCTION "public"."process_rendimento_beneficios"();



CREATE OR REPLACE TRIGGER "trigger_process_servicos_politicas" BEFORE INSERT OR UPDATE ON "public"."Sociocultural Profile" FOR EACH ROW EXECUTE FUNCTION "public"."process_servicos_politicas"();



ALTER TABLE "public"."attendance"
    ADD CONSTRAINT "attendance_schedule_fk" FOREIGN KEY ("schedule_id") REFERENCES "public"."schedule"("unique_id") ON DELETE RESTRICT;



ALTER TABLE "public"."attendance"
    ADD CONSTRAINT "attendance_student_fk" FOREIGN KEY ("student_id") REFERENCES "public"."Students"("unique id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."caravana_sinta_o_som"
    ADD CONSTRAINT "caravana_sinta_o_som_patrocinador_fkey" FOREIGN KEY ("patrocinador") REFERENCES "public"."sponsors"("unique_id");



ALTER TABLE ONLY "public"."Customer Satisfaction Survey"
    ADD CONSTRAINT "fk_customer_satisfaction_caravana" FOREIGN KEY ("caravana") REFERENCES "public"."caravana_sinta_o_som"("unique_id");



ALTER TABLE ONLY "public"."student_satisfaction_survey"
    ADD CONSTRAINT "fk_student" FOREIGN KEY ("student") REFERENCES "public"."Students"("unique id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."student_impact_survey"
    ADD CONSTRAINT "fk_student_impact_survey_student" FOREIGN KEY ("student") REFERENCES "public"."Students"("unique id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."rel_media_survey_monitoramento_sinta_som"
    ADD CONSTRAINT "fk_survey_monitoramento_sinta_som" FOREIGN KEY ("survey_unique_id") REFERENCES "public"."survey_monitoramento_sinta_som"("unique_id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."teacher_impact_survey"
    ADD CONSTRAINT "fk_teacher" FOREIGN KEY ("teacher") REFERENCES "public"."Teachers"("unique id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."parent_satisfaction_survey"
    ADD CONSTRAINT "parent_satisfaction_survey_student_fkey" FOREIGN KEY ("student") REFERENCES "public"."Students"("unique id") ON UPDATE CASCADE ON DELETE RESTRICT;



ALTER TABLE ONLY "public"."program_classes"
    ADD CONSTRAINT "program_classes_class_unique_id_fkey" FOREIGN KEY ("class_unique_id") REFERENCES "public"."class"("unique_id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."program_classes"
    ADD CONSTRAINT "program_classes_program_id_fkey" FOREIGN KEY ("program_id") REFERENCES "public"."programs"("unique_id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."program_instruments"
    ADD CONSTRAINT "program_instruments_instrument_os_id_fkey" FOREIGN KEY ("instrument_os_id") REFERENCES "public"."instrument_os"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."program_instruments"
    ADD CONSTRAINT "program_instruments_program_id_fkey" FOREIGN KEY ("program_id") REFERENCES "public"."programs"("unique_id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."program_patrocinadores"
    ADD CONSTRAINT "program_patrocinadores_program_id_fkey" FOREIGN KEY ("program_id") REFERENCES "public"."programs"("unique_id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."program_patrocinadores"
    ADD CONSTRAINT "program_patrocinadores_sponsor_id_fkey" FOREIGN KEY ("sponsor_id") REFERENCES "public"."sponsors"("unique_id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."program_teachers"
    ADD CONSTRAINT "program_teachers_program_id_fkey" FOREIGN KEY ("program_id") REFERENCES "public"."programs"("unique_id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."program_teachers"
    ADD CONSTRAINT "program_teachers_teacher_unique_id_fkey" FOREIGN KEY ("teacher_unique_id") REFERENCES "public"."Teachers"("unique id") ON DELETE CASCADE;



ALTER TABLE "public"."Customer Satisfaction Survey" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."Customer Satisfaction Survey options" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."Inscrições Treinamento" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."Parents" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "Permissao total anon" ON "public"."sinta_o_som_survey_teacher" TO "anon" USING (true) WITH CHECK (true);



CREATE POLICY "Permissao total authenticated" ON "public"."sinta_o_som_survey_teacher" TO "authenticated" USING (true) WITH CHECK (true);



CREATE POLICY "Permitir inserção anônima" ON "public"."funarte_avaliacao_aluno" FOR INSERT TO "anon" WITH CHECK (true);



CREATE POLICY "Permitir leitura anônima" ON "public"."funarte_avaliacao_aluno" FOR SELECT TO "anon" USING (true);



ALTER TABLE "public"."Rate students" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."Santander_Formularios" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."Sociocultural Profile" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."Students" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."Survey_Masterclass_Sinta_Som" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."Teachers" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "add students" ON "public"."Students" TO "anon" USING (true) WITH CHECK (true);



CREATE POLICY "all" ON "public"."class" TO "anon" USING (true) WITH CHECK (true);



CREATE POLICY "all" ON "public"."schedule" TO "anon" USING (true) WITH CHECK (true);



CREATE POLICY "allow_all_anon_class" ON "public"."class" TO "anon" USING (true) WITH CHECK (true);



CREATE POLICY "allow_all_anon_customer_satisfaction_survey" ON "public"."Customer Satisfaction Survey" TO "anon" USING (true) WITH CHECK (true);



CREATE POLICY "allow_all_anon_customer_satisfaction_survey_options" ON "public"."Customer Satisfaction Survey options" TO "anon" USING (true) WITH CHECK (true);



CREATE POLICY "allow_all_anon_indicadores_ibme" ON "public"."indicadores_ibme" TO "anon" USING (true) WITH CHECK (true);



CREATE POLICY "allow_all_anon_instrument_os" ON "public"."instrument_os" TO "anon" USING (true) WITH CHECK (true);



CREATE POLICY "allow_all_anon_invite_code" ON "public"."students_invite_code" TO "anon" USING (true) WITH CHECK (true);



CREATE POLICY "allow_all_anon_parents" ON "public"."Parents" TO "anon" USING (true) WITH CHECK (true);



CREATE POLICY "allow_all_anon_program_classes" ON "public"."program_classes" TO "anon" USING (true) WITH CHECK (true);



CREATE POLICY "allow_all_anon_program_instruments" ON "public"."program_instruments" TO "anon" USING (true) WITH CHECK (true);



CREATE POLICY "allow_all_anon_program_patrocinadores" ON "public"."program_patrocinadores" TO "anon" USING (true) WITH CHECK (true);



CREATE POLICY "allow_all_anon_program_teachers" ON "public"."program_teachers" TO "anon" USING (true) WITH CHECK (true);



CREATE POLICY "allow_all_anon_programs" ON "public"."programs" TO "anon" USING (true) WITH CHECK (true);



CREATE POLICY "allow_all_anon_rate_students" ON "public"."Rate students" TO "anon" USING (true) WITH CHECK (true);



CREATE POLICY "allow_all_anon_schedule" ON "public"."schedule" TO "anon" USING (true) WITH CHECK (true);



CREATE POLICY "allow_all_anon_sociocultural_profile" ON "public"."Sociocultural Profile" TO "anon" USING (true) WITH CHECK (true);



CREATE POLICY "allow_all_anon_sponsors" ON "public"."sponsors" TO "anon" USING (true) WITH CHECK (true);



CREATE POLICY "allow_all_anon_students" ON "public"."Students" TO "anon" USING (true) WITH CHECK (true);



CREATE POLICY "allow_all_anon_teachers" ON "public"."Teachers" TO "anon" USING (true) WITH CHECK (true);



CREATE POLICY "allow_all_anon_wake_up_supabase" ON "public"."wake_up_supabase" TO "anon" USING (true) WITH CHECK (true);



CREATE POLICY "allow_all_auth_class" ON "public"."class" TO "authenticated" USING (true) WITH CHECK (true);



CREATE POLICY "allow_all_auth_customer_satisfaction_survey" ON "public"."Customer Satisfaction Survey" TO "authenticated" USING (true) WITH CHECK (true);



CREATE POLICY "allow_all_auth_customer_satisfaction_survey_options" ON "public"."Customer Satisfaction Survey options" TO "authenticated" USING (true) WITH CHECK (true);



CREATE POLICY "allow_all_auth_indicadores_ibme" ON "public"."indicadores_ibme" TO "authenticated" USING (true) WITH CHECK (true);



CREATE POLICY "allow_all_auth_instrument_os" ON "public"."instrument_os" TO "authenticated" USING (true) WITH CHECK (true);



CREATE POLICY "allow_all_auth_parents" ON "public"."Parents" TO "authenticated" USING (true) WITH CHECK (true);



CREATE POLICY "allow_all_auth_program_classes" ON "public"."program_classes" TO "authenticated" USING (true) WITH CHECK (true);



CREATE POLICY "allow_all_auth_program_instruments" ON "public"."program_instruments" TO "authenticated" USING (true) WITH CHECK (true);



CREATE POLICY "allow_all_auth_program_patrocinadores" ON "public"."program_patrocinadores" TO "authenticated" USING (true) WITH CHECK (true);



CREATE POLICY "allow_all_auth_program_teachers" ON "public"."program_teachers" TO "authenticated" USING (true) WITH CHECK (true);



CREATE POLICY "allow_all_auth_programs" ON "public"."programs" TO "authenticated" USING (true) WITH CHECK (true);



CREATE POLICY "allow_all_auth_rate_students" ON "public"."Rate students" TO "authenticated" USING (true) WITH CHECK (true);



CREATE POLICY "allow_all_auth_schedule" ON "public"."schedule" TO "authenticated" USING (true) WITH CHECK (true);



CREATE POLICY "allow_all_auth_sociocultural_profile" ON "public"."Sociocultural Profile" TO "authenticated" USING (true) WITH CHECK (true);



CREATE POLICY "allow_all_auth_sponsors" ON "public"."sponsors" TO "authenticated" USING (true) WITH CHECK (true);



CREATE POLICY "allow_all_auth_students" ON "public"."Students" TO "authenticated" USING (true) WITH CHECK (true);



CREATE POLICY "allow_all_auth_teachers" ON "public"."Teachers" TO "authenticated" USING (true) WITH CHECK (true);



CREATE POLICY "allow_all_auth_wake_up_supabase" ON "public"."wake_up_supabase" TO "authenticated" USING (true) WITH CHECK (true);



CREATE POLICY "allow_all_for_anonymous_and_authenticated" ON "public"."Santander_Formularios" TO "authenticated", "anon" USING (true) WITH CHECK (true);



CREATE POLICY "allow_anon_rel_media_survey_monitoramento_sinta_som" ON "public"."rel_media_survey_monitoramento_sinta_som" TO "anon" USING (true) WITH CHECK (true);



CREATE POLICY "allow_anon_sinta_o_som_student" ON "public"."survey_sinta_o_som_aluno" TO "anon" USING (true) WITH CHECK (true);



CREATE POLICY "allow_anon_student_satisfaction_survey" ON "public"."student_satisfaction_survey" TO "anon" USING (true) WITH CHECK (true);



CREATE POLICY "allow_anon_survey_monitoramento_sinta_som" ON "public"."survey_monitoramento_sinta_som" TO "anon" USING (true) WITH CHECK (true);



CREATE POLICY "allow_anon_teacher_impact_survey" ON "public"."teacher_impact_survey" TO "anon" USING (true) WITH CHECK (true);



CREATE POLICY "anon" ON "public"."Customer Satisfaction Survey" TO "authenticated", "anon", "service_role" USING (true) WITH CHECK (true);



CREATE POLICY "anon" ON "public"."Survey_Masterclass_Sinta_Som" TO "anon" USING (true) WITH CHECK (true);



CREATE POLICY "anon" ON "public"."parent_satisfaction_survey" TO "authenticated", "anon" USING (true) WITH CHECK (true);



CREATE POLICY "anon" ON "public"."relatorios_sinta_som" TO "anon" USING (true) WITH CHECK (true);



CREATE POLICY "anon_all_funarate_avaliacao_responsaveis" ON "public"."funarate_avaliacao_responsaveis" TO "anon" USING (true) WITH CHECK (true);



CREATE POLICY "anon_permissive" ON "public"."student_impact_survey" TO "authenticated", "anon" USING (true) WITH CHECK (true);



CREATE POLICY "caravana_anon" ON "public"."caravana_sinta_o_som" TO "authenticated", "anon" USING (true) WITH CHECK (true);



ALTER TABLE "public"."caravana_sinta_o_som" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."class" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."funarate_avaliacao_responsaveis" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."funarte_avaliacao_aluno" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."indicadores_ibme" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."instrument_os" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."inventory" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."parent_satisfaction_survey" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."patrimonio" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "permissive" ON "public"."Inscrições Treinamento" TO "authenticated", "anon" USING (true) WITH CHECK (true);



ALTER TABLE "public"."program_classes" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."program_instruments" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."program_patrocinadores" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."program_teachers" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."programs" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "public" ON "public"."Customer Satisfaction Survey options" FOR SELECT USING (true);



ALTER TABLE "public"."rel_media_survey_monitoramento_sinta_som" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."relatorios_sinta_som" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."schedule" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "service_role_full_access_inventory" ON "public"."inventory" TO "service_role" USING (true) WITH CHECK (true);



CREATE POLICY "service_role_full_access_patrimonio" ON "public"."patrimonio" TO "service_role" USING (true) WITH CHECK (true);



ALTER TABLE "public"."sinta_o_som_survey_teacher" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."sponsors" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."student_impact_survey" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."student_satisfaction_survey" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."students_invite_code" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."survey_monitoramento_sinta_som" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."survey_sinta_o_som_aluno" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."teacher_impact_survey" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "upsert parents" ON "public"."Parents" TO "anon" USING (true) WITH CHECK (true);



CREATE POLICY "upsert teacher" ON "public"."Teachers" TO "anon" USING (true) WITH CHECK (true);



ALTER TABLE "public"."wake_up_supabase" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "wakup" ON "public"."wake_up_supabase" USING (true) WITH CHECK (true);



GRANT USAGE ON SCHEMA "public" TO "postgres";
GRANT USAGE ON SCHEMA "public" TO "anon";
GRANT USAGE ON SCHEMA "public" TO "authenticated";
GRANT USAGE ON SCHEMA "public" TO "service_role";



GRANT ALL ON FUNCTION "public"."assign_caravana_to_customer_survey"("p_cidade" "text", "p_estado" "text", "p_caravana_unique_id" "text") TO "anon";
GRANT ALL ON FUNCTION "public"."assign_caravana_to_customer_survey"("p_cidade" "text", "p_estado" "text", "p_caravana_unique_id" "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."assign_caravana_to_customer_survey"("p_cidade" "text", "p_estado" "text", "p_caravana_unique_id" "text") TO "service_role";



GRANT ALL ON FUNCTION "public"."bulk_create_schedules"("p_schedules" "jsonb") TO "anon";
GRANT ALL ON FUNCTION "public"."bulk_create_schedules"("p_schedules" "jsonb") TO "authenticated";
GRANT ALL ON FUNCTION "public"."bulk_create_schedules"("p_schedules" "jsonb") TO "service_role";



GRANT ALL ON FUNCTION "public"."bulk_update_attendance"("attendance_updates" "jsonb") TO "anon";
GRANT ALL ON FUNCTION "public"."bulk_update_attendance"("attendance_updates" "jsonb") TO "authenticated";
GRANT ALL ON FUNCTION "public"."bulk_update_attendance"("attendance_updates" "jsonb") TO "service_role";



GRANT ALL ON FUNCTION "public"."bulk_update_attendance_by_student"("p_schedule_id" "text", "attendance_updates" "jsonb") TO "anon";
GRANT ALL ON FUNCTION "public"."bulk_update_attendance_by_student"("p_schedule_id" "text", "attendance_updates" "jsonb") TO "authenticated";
GRANT ALL ON FUNCTION "public"."bulk_update_attendance_by_student"("p_schedule_id" "text", "attendance_updates" "jsonb") TO "service_role";



GRANT ALL ON FUNCTION "public"."check_attendance_date_matches_schedule"() TO "anon";
GRANT ALL ON FUNCTION "public"."check_attendance_date_matches_schedule"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."check_attendance_date_matches_schedule"() TO "service_role";



GRANT ALL ON FUNCTION "public"."create_attendance_partition"("year_to_create" integer) TO "anon";
GRANT ALL ON FUNCTION "public"."create_attendance_partition"("year_to_create" integer) TO "authenticated";
GRANT ALL ON FUNCTION "public"."create_attendance_partition"("year_to_create" integer) TO "service_role";



GRANT ALL ON FUNCTION "public"."create_attendance_records"() TO "anon";
GRANT ALL ON FUNCTION "public"."create_attendance_records"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."create_attendance_records"() TO "service_role";



GRANT ALL ON FUNCTION "public"."delete_expired_invite_codes"() TO "anon";
GRANT ALL ON FUNCTION "public"."delete_expired_invite_codes"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."delete_expired_invite_codes"() TO "service_role";



GRANT ALL ON FUNCTION "public"."get_all_sociocultural_stats"("filter_instrument" "text", "filter_gender" "text", "filter_ethnicity" "text", "filter_age_range" "text", "filter_date_start" "text", "filter_date_end" "text", "filter_status" "text", "filter_classes" "text", "filter_programa" "text", "filter_teacher" "text", "filter_sponsor" "text") TO "anon";
GRANT ALL ON FUNCTION "public"."get_all_sociocultural_stats"("filter_instrument" "text", "filter_gender" "text", "filter_ethnicity" "text", "filter_age_range" "text", "filter_date_start" "text", "filter_date_end" "text", "filter_status" "text", "filter_classes" "text", "filter_programa" "text", "filter_teacher" "text", "filter_sponsor" "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."get_all_sociocultural_stats"("filter_instrument" "text", "filter_gender" "text", "filter_ethnicity" "text", "filter_age_range" "text", "filter_date_start" "text", "filter_date_end" "text", "filter_status" "text", "filter_classes" "text", "filter_programa" "text", "filter_teacher" "text", "filter_sponsor" "text") TO "service_role";



GRANT ALL ON FUNCTION "public"."get_estatisticas_ibme"("filtro_programa" "text") TO "anon";
GRANT ALL ON FUNCTION "public"."get_estatisticas_ibme"("filtro_programa" "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."get_estatisticas_ibme"("filtro_programa" "text") TO "service_role";



GRANT ALL ON FUNCTION "public"."get_satisfaction_counts_filtered"("p_city" "text", "p_end_date" "date", "p_include_total" boolean, "p_start_date" "date", "p_state" "text", "p_sponsor" "text") TO "anon";
GRANT ALL ON FUNCTION "public"."get_satisfaction_counts_filtered"("p_city" "text", "p_end_date" "date", "p_include_total" boolean, "p_start_date" "date", "p_state" "text", "p_sponsor" "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."get_satisfaction_counts_filtered"("p_city" "text", "p_end_date" "date", "p_include_total" boolean, "p_start_date" "date", "p_state" "text", "p_sponsor" "text") TO "service_role";



GRANT ALL ON FUNCTION "public"."get_satisfaction_survey"("p_city" "text", "p_state" "text", "p_start_date" "date", "p_end_date" "date") TO "anon";
GRANT ALL ON FUNCTION "public"."get_satisfaction_survey"("p_city" "text", "p_state" "text", "p_start_date" "date", "p_end_date" "date") TO "authenticated";
GRANT ALL ON FUNCTION "public"."get_satisfaction_survey"("p_city" "text", "p_state" "text", "p_start_date" "date", "p_end_date" "date") TO "service_role";



GRANT ALL ON FUNCTION "public"."get_sinta_som_stats"("p_city" "text", "p_state" "text", "p_start_date" "date", "p_end_date" "date", "p_include_total" boolean) TO "anon";
GRANT ALL ON FUNCTION "public"."get_sinta_som_stats"("p_city" "text", "p_state" "text", "p_start_date" "date", "p_end_date" "date", "p_include_total" boolean) TO "authenticated";
GRANT ALL ON FUNCTION "public"."get_sinta_som_stats"("p_city" "text", "p_state" "text", "p_start_date" "date", "p_end_date" "date", "p_include_total" boolean) TO "service_role";



GRANT ALL ON FUNCTION "public"."get_stats_area_risco"() TO "anon";
GRANT ALL ON FUNCTION "public"."get_stats_area_risco"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."get_stats_area_risco"() TO "service_role";



GRANT ALL ON FUNCTION "public"."get_stats_area_risco"("filter_instrument" "text", "filter_gender" "text", "filter_ethnicity" "text", "filter_age_range" "text", "filter_date_start" "text", "filter_date_end" "text", "filter_status" "text", "filter_classes" "text", "filter_programa" "text", "filter_teacher" "text", "filter_sponsor" "text") TO "anon";
GRANT ALL ON FUNCTION "public"."get_stats_area_risco"("filter_instrument" "text", "filter_gender" "text", "filter_ethnicity" "text", "filter_age_range" "text", "filter_date_start" "text", "filter_date_end" "text", "filter_status" "text", "filter_classes" "text", "filter_programa" "text", "filter_teacher" "text", "filter_sponsor" "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."get_stats_area_risco"("filter_instrument" "text", "filter_gender" "text", "filter_ethnicity" "text", "filter_age_range" "text", "filter_date_start" "text", "filter_date_end" "text", "filter_status" "text", "filter_classes" "text", "filter_programa" "text", "filter_teacher" "text", "filter_sponsor" "text") TO "service_role";



GRANT ALL ON FUNCTION "public"."get_stats_cursando"() TO "anon";
GRANT ALL ON FUNCTION "public"."get_stats_cursando"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."get_stats_cursando"() TO "service_role";



GRANT ALL ON FUNCTION "public"."get_stats_cursando"("filter_instrument" "text", "filter_gender" "text", "filter_ethnicity" "text", "filter_age_range" "text", "filter_date_start" "text", "filter_date_end" "text", "filter_status" "text", "filter_classes" "text", "filter_programa" "text", "filter_teacher" "text", "filter_sponsor" "text") TO "anon";
GRANT ALL ON FUNCTION "public"."get_stats_cursando"("filter_instrument" "text", "filter_gender" "text", "filter_ethnicity" "text", "filter_age_range" "text", "filter_date_start" "text", "filter_date_end" "text", "filter_status" "text", "filter_classes" "text", "filter_programa" "text", "filter_teacher" "text", "filter_sponsor" "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."get_stats_cursando"("filter_instrument" "text", "filter_gender" "text", "filter_ethnicity" "text", "filter_age_range" "text", "filter_date_start" "text", "filter_date_end" "text", "filter_status" "text", "filter_classes" "text", "filter_programa" "text", "filter_teacher" "text", "filter_sponsor" "text") TO "service_role";



GRANT ALL ON FUNCTION "public"."get_stats_escolaridade_mae"() TO "anon";
GRANT ALL ON FUNCTION "public"."get_stats_escolaridade_mae"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."get_stats_escolaridade_mae"() TO "service_role";



GRANT ALL ON FUNCTION "public"."get_stats_escolaridade_mae"("filter_instrument" "text", "filter_gender" "text", "filter_ethnicity" "text", "filter_age_range" "text", "filter_date_start" "text", "filter_date_end" "text", "filter_status" "text", "filter_classes" "text", "filter_programa" "text", "filter_teacher" "text", "filter_sponsor" "text") TO "anon";
GRANT ALL ON FUNCTION "public"."get_stats_escolaridade_mae"("filter_instrument" "text", "filter_gender" "text", "filter_ethnicity" "text", "filter_age_range" "text", "filter_date_start" "text", "filter_date_end" "text", "filter_status" "text", "filter_classes" "text", "filter_programa" "text", "filter_teacher" "text", "filter_sponsor" "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."get_stats_escolaridade_mae"("filter_instrument" "text", "filter_gender" "text", "filter_ethnicity" "text", "filter_age_range" "text", "filter_date_start" "text", "filter_date_end" "text", "filter_status" "text", "filter_classes" "text", "filter_programa" "text", "filter_teacher" "text", "filter_sponsor" "text") TO "service_role";



GRANT ALL ON FUNCTION "public"."get_stats_escolaridade_pai"() TO "anon";
GRANT ALL ON FUNCTION "public"."get_stats_escolaridade_pai"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."get_stats_escolaridade_pai"() TO "service_role";



GRANT ALL ON FUNCTION "public"."get_stats_escolaridade_pai"("filter_instrument" "text", "filter_gender" "text", "filter_ethnicity" "text", "filter_age_range" "text", "filter_date_start" "text", "filter_date_end" "text", "filter_status" "text", "filter_classes" "text", "filter_programa" "text", "filter_teacher" "text", "filter_sponsor" "text") TO "anon";
GRANT ALL ON FUNCTION "public"."get_stats_escolaridade_pai"("filter_instrument" "text", "filter_gender" "text", "filter_ethnicity" "text", "filter_age_range" "text", "filter_date_start" "text", "filter_date_end" "text", "filter_status" "text", "filter_classes" "text", "filter_programa" "text", "filter_teacher" "text", "filter_sponsor" "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."get_stats_escolaridade_pai"("filter_instrument" "text", "filter_gender" "text", "filter_ethnicity" "text", "filter_age_range" "text", "filter_date_start" "text", "filter_date_end" "text", "filter_status" "text", "filter_classes" "text", "filter_programa" "text", "filter_teacher" "text", "filter_sponsor" "text") TO "service_role";



GRANT ALL ON FUNCTION "public"."get_stats_etnia"("filter_programa" "text", "filter_status" "text", "filter_sponsor" "text", "filter_etnia" "text", "filter_instrumento" "text", "filter_professor" "text", "filter_turma" "text", "filter_genero" "text", "filter_faixa_etaria" "text") TO "anon";
GRANT ALL ON FUNCTION "public"."get_stats_etnia"("filter_programa" "text", "filter_status" "text", "filter_sponsor" "text", "filter_etnia" "text", "filter_instrumento" "text", "filter_professor" "text", "filter_turma" "text", "filter_genero" "text", "filter_faixa_etaria" "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."get_stats_etnia"("filter_programa" "text", "filter_status" "text", "filter_sponsor" "text", "filter_etnia" "text", "filter_instrumento" "text", "filter_professor" "text", "filter_turma" "text", "filter_genero" "text", "filter_faixa_etaria" "text") TO "service_role";



GRANT ALL ON FUNCTION "public"."get_stats_mora_comunidade"() TO "anon";
GRANT ALL ON FUNCTION "public"."get_stats_mora_comunidade"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."get_stats_mora_comunidade"() TO "service_role";



GRANT ALL ON FUNCTION "public"."get_stats_mora_comunidade"("filter_instrument" "text", "filter_gender" "text", "filter_ethnicity" "text", "filter_age_range" "text", "filter_date_start" "text", "filter_date_end" "text", "filter_status" "text", "filter_classes" "text", "filter_programa" "text", "filter_teacher" "text", "filter_sponsor" "text") TO "anon";
GRANT ALL ON FUNCTION "public"."get_stats_mora_comunidade"("filter_instrument" "text", "filter_gender" "text", "filter_ethnicity" "text", "filter_age_range" "text", "filter_date_start" "text", "filter_date_end" "text", "filter_status" "text", "filter_classes" "text", "filter_programa" "text", "filter_teacher" "text", "filter_sponsor" "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."get_stats_mora_comunidade"("filter_instrument" "text", "filter_gender" "text", "filter_ethnicity" "text", "filter_age_range" "text", "filter_date_start" "text", "filter_date_end" "text", "filter_status" "text", "filter_classes" "text", "filter_programa" "text", "filter_teacher" "text", "filter_sponsor" "text") TO "service_role";



GRANT ALL ON FUNCTION "public"."get_stats_pavimentacao"() TO "anon";
GRANT ALL ON FUNCTION "public"."get_stats_pavimentacao"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."get_stats_pavimentacao"() TO "service_role";



GRANT ALL ON FUNCTION "public"."get_stats_pavimentacao"("filter_instrument" "text", "filter_gender" "text", "filter_ethnicity" "text", "filter_age_range" "text", "filter_date_start" "text", "filter_date_end" "text", "filter_status" "text", "filter_classes" "text", "filter_programa" "text", "filter_teacher" "text", "filter_sponsor" "text") TO "anon";
GRANT ALL ON FUNCTION "public"."get_stats_pavimentacao"("filter_instrument" "text", "filter_gender" "text", "filter_ethnicity" "text", "filter_age_range" "text", "filter_date_start" "text", "filter_date_end" "text", "filter_status" "text", "filter_classes" "text", "filter_programa" "text", "filter_teacher" "text", "filter_sponsor" "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."get_stats_pavimentacao"("filter_instrument" "text", "filter_gender" "text", "filter_ethnicity" "text", "filter_age_range" "text", "filter_date_start" "text", "filter_date_end" "text", "filter_status" "text", "filter_classes" "text", "filter_programa" "text", "filter_teacher" "text", "filter_sponsor" "text") TO "service_role";



GRANT ALL ON FUNCTION "public"."get_stats_qtde_moradores"() TO "anon";
GRANT ALL ON FUNCTION "public"."get_stats_qtde_moradores"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."get_stats_qtde_moradores"() TO "service_role";



GRANT ALL ON FUNCTION "public"."get_stats_qtde_moradores"("filter_instrument" "text", "filter_gender" "text", "filter_ethnicity" "text", "filter_age_range" "text", "filter_date_start" "text", "filter_date_end" "text", "filter_status" "text", "filter_classes" "text", "filter_programa" "text", "filter_teacher" "text", "filter_sponsor" "text") TO "anon";
GRANT ALL ON FUNCTION "public"."get_stats_qtde_moradores"("filter_instrument" "text", "filter_gender" "text", "filter_ethnicity" "text", "filter_age_range" "text", "filter_date_start" "text", "filter_date_end" "text", "filter_status" "text", "filter_classes" "text", "filter_programa" "text", "filter_teacher" "text", "filter_sponsor" "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."get_stats_qtde_moradores"("filter_instrument" "text", "filter_gender" "text", "filter_ethnicity" "text", "filter_age_range" "text", "filter_date_start" "text", "filter_date_end" "text", "filter_status" "text", "filter_classes" "text", "filter_programa" "text", "filter_teacher" "text", "filter_sponsor" "text") TO "service_role";



GRANT ALL ON FUNCTION "public"."get_stats_recebe_ibme"() TO "anon";
GRANT ALL ON FUNCTION "public"."get_stats_recebe_ibme"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."get_stats_recebe_ibme"() TO "service_role";



GRANT ALL ON FUNCTION "public"."get_stats_recebe_ibme"("filter_instrument" "text", "filter_gender" "text", "filter_ethnicity" "text", "filter_age_range" "text", "filter_date_start" "text", "filter_date_end" "text", "filter_status" "text", "filter_classes" "text", "filter_programa" "text", "filter_teacher" "text", "filter_sponsor" "text") TO "anon";
GRANT ALL ON FUNCTION "public"."get_stats_recebe_ibme"("filter_instrument" "text", "filter_gender" "text", "filter_ethnicity" "text", "filter_age_range" "text", "filter_date_start" "text", "filter_date_end" "text", "filter_status" "text", "filter_classes" "text", "filter_programa" "text", "filter_teacher" "text", "filter_sponsor" "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."get_stats_recebe_ibme"("filter_instrument" "text", "filter_gender" "text", "filter_ethnicity" "text", "filter_age_range" "text", "filter_date_start" "text", "filter_date_end" "text", "filter_status" "text", "filter_classes" "text", "filter_programa" "text", "filter_teacher" "text", "filter_sponsor" "text") TO "service_role";



GRANT ALL ON FUNCTION "public"."get_stats_regiao"() TO "anon";
GRANT ALL ON FUNCTION "public"."get_stats_regiao"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."get_stats_regiao"() TO "service_role";



GRANT ALL ON FUNCTION "public"."get_stats_regiao"("filter_instrument" "text", "filter_gender" "text", "filter_ethnicity" "text", "filter_age_range" "text", "filter_date_start" "text", "filter_date_end" "text", "filter_status" "text", "filter_classes" "text", "filter_programa" "text", "filter_teacher" "text", "filter_sponsor" "text") TO "anon";
GRANT ALL ON FUNCTION "public"."get_stats_regiao"("filter_instrument" "text", "filter_gender" "text", "filter_ethnicity" "text", "filter_age_range" "text", "filter_date_start" "text", "filter_date_end" "text", "filter_status" "text", "filter_classes" "text", "filter_programa" "text", "filter_teacher" "text", "filter_sponsor" "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."get_stats_regiao"("filter_instrument" "text", "filter_gender" "text", "filter_ethnicity" "text", "filter_age_range" "text", "filter_date_start" "text", "filter_date_end" "text", "filter_status" "text", "filter_classes" "text", "filter_programa" "text", "filter_teacher" "text", "filter_sponsor" "text") TO "service_role";



GRANT ALL ON FUNCTION "public"."get_stats_renda_familiar"() TO "anon";
GRANT ALL ON FUNCTION "public"."get_stats_renda_familiar"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."get_stats_renda_familiar"() TO "service_role";



GRANT ALL ON FUNCTION "public"."get_stats_renda_familiar"("filter_instrument" "text", "filter_gender" "text", "filter_ethnicity" "text", "filter_age_range" "text", "filter_date_start" "text", "filter_date_end" "text", "filter_status" "text", "filter_classes" "text", "filter_programa" "text", "filter_teacher" "text", "filter_sponsor" "text") TO "anon";
GRANT ALL ON FUNCTION "public"."get_stats_renda_familiar"("filter_instrument" "text", "filter_gender" "text", "filter_ethnicity" "text", "filter_age_range" "text", "filter_date_start" "text", "filter_date_end" "text", "filter_status" "text", "filter_classes" "text", "filter_programa" "text", "filter_teacher" "text", "filter_sponsor" "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."get_stats_renda_familiar"("filter_instrument" "text", "filter_gender" "text", "filter_ethnicity" "text", "filter_age_range" "text", "filter_date_start" "text", "filter_date_end" "text", "filter_status" "text", "filter_classes" "text", "filter_programa" "text", "filter_teacher" "text", "filter_sponsor" "text") TO "service_role";



GRANT ALL ON FUNCTION "public"."get_stats_rendimentos_beneficios"() TO "anon";
GRANT ALL ON FUNCTION "public"."get_stats_rendimentos_beneficios"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."get_stats_rendimentos_beneficios"() TO "service_role";



GRANT ALL ON FUNCTION "public"."get_stats_rendimentos_beneficios"("filter_instrument" "text", "filter_gender" "text", "filter_ethnicity" "text", "filter_age_range" "text", "filter_date_start" "text", "filter_date_end" "text", "filter_status" "text", "filter_classes" "text", "filter_programa" "text", "filter_teacher" "text", "filter_sponsor" "text") TO "anon";
GRANT ALL ON FUNCTION "public"."get_stats_rendimentos_beneficios"("filter_instrument" "text", "filter_gender" "text", "filter_ethnicity" "text", "filter_age_range" "text", "filter_date_start" "text", "filter_date_end" "text", "filter_status" "text", "filter_classes" "text", "filter_programa" "text", "filter_teacher" "text", "filter_sponsor" "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."get_stats_rendimentos_beneficios"("filter_instrument" "text", "filter_gender" "text", "filter_ethnicity" "text", "filter_age_range" "text", "filter_date_start" "text", "filter_date_end" "text", "filter_status" "text", "filter_classes" "text", "filter_programa" "text", "filter_teacher" "text", "filter_sponsor" "text") TO "service_role";



GRANT ALL ON FUNCTION "public"."get_stats_servicos_politicas"() TO "anon";
GRANT ALL ON FUNCTION "public"."get_stats_servicos_politicas"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."get_stats_servicos_politicas"() TO "service_role";



GRANT ALL ON FUNCTION "public"."get_stats_servicos_politicas"("filter_instrument" "text", "filter_gender" "text", "filter_ethnicity" "text", "filter_age_range" "text", "filter_date_start" "text", "filter_date_end" "text", "filter_status" "text", "filter_classes" "text", "filter_programa" "text", "filter_teacher" "text", "filter_sponsor" "text") TO "anon";
GRANT ALL ON FUNCTION "public"."get_stats_servicos_politicas"("filter_instrument" "text", "filter_gender" "text", "filter_ethnicity" "text", "filter_age_range" "text", "filter_date_start" "text", "filter_date_end" "text", "filter_status" "text", "filter_classes" "text", "filter_programa" "text", "filter_teacher" "text", "filter_sponsor" "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."get_stats_servicos_politicas"("filter_instrument" "text", "filter_gender" "text", "filter_ethnicity" "text", "filter_age_range" "text", "filter_date_start" "text", "filter_date_end" "text", "filter_status" "text", "filter_classes" "text", "filter_programa" "text", "filter_teacher" "text", "filter_sponsor" "text") TO "service_role";



GRANT ALL ON FUNCTION "public"."get_student_survey_stats"("p_city" "text", "p_state" "text", "p_class" "text", "p_program" "text", "p_start_date" "date", "p_end_date" "date", "p_include_total" boolean) TO "anon";
GRANT ALL ON FUNCTION "public"."get_student_survey_stats"("p_city" "text", "p_state" "text", "p_class" "text", "p_program" "text", "p_start_date" "date", "p_end_date" "date", "p_include_total" boolean) TO "authenticated";
GRANT ALL ON FUNCTION "public"."get_student_survey_stats"("p_city" "text", "p_state" "text", "p_class" "text", "p_program" "text", "p_start_date" "date", "p_end_date" "date", "p_include_total" boolean) TO "service_role";



GRANT ALL ON FUNCTION "public"."get_student_unique_id_by_name_dob"("p_fullname" "text", "p_dob" "text") TO "anon";
GRANT ALL ON FUNCTION "public"."get_student_unique_id_by_name_dob"("p_fullname" "text", "p_dob" "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."get_student_unique_id_by_name_dob"("p_fullname" "text", "p_dob" "text") TO "service_role";



GRANT ALL ON FUNCTION "public"."get_survey_monitoramento_sinta_som_report"("p_class" "text", "p_program" "text", "p_uf" "text", "p_cidade" "text", "p_start_date" "date", "p_end_date" "date") TO "anon";
GRANT ALL ON FUNCTION "public"."get_survey_monitoramento_sinta_som_report"("p_class" "text", "p_program" "text", "p_uf" "text", "p_cidade" "text", "p_start_date" "date", "p_end_date" "date") TO "authenticated";
GRANT ALL ON FUNCTION "public"."get_survey_monitoramento_sinta_som_report"("p_class" "text", "p_program" "text", "p_uf" "text", "p_cidade" "text", "p_start_date" "date", "p_end_date" "date") TO "service_role";



GRANT ALL ON FUNCTION "public"."get_survey_sinta_o_som_stats"("p_city" "text", "p_state" "text", "p_class" "text", "p_program" "text", "p_start_date" "date", "p_end_date" "date", "p_include_total" boolean) TO "anon";
GRANT ALL ON FUNCTION "public"."get_survey_sinta_o_som_stats"("p_city" "text", "p_state" "text", "p_class" "text", "p_program" "text", "p_start_date" "date", "p_end_date" "date", "p_include_total" boolean) TO "authenticated";
GRANT ALL ON FUNCTION "public"."get_survey_sinta_o_som_stats"("p_city" "text", "p_state" "text", "p_class" "text", "p_program" "text", "p_start_date" "date", "p_end_date" "date", "p_include_total" boolean) TO "service_role";



GRANT ALL ON FUNCTION "public"."get_teacher_impact_survey_stats"("p_city" "text", "p_state" "text", "p_program" "text", "p_teacher" "text", "p_start_date" "date", "p_end_date" "date", "p_include_total" boolean) TO "anon";
GRANT ALL ON FUNCTION "public"."get_teacher_impact_survey_stats"("p_city" "text", "p_state" "text", "p_program" "text", "p_teacher" "text", "p_start_date" "date", "p_end_date" "date", "p_include_total" boolean) TO "authenticated";
GRANT ALL ON FUNCTION "public"."get_teacher_impact_survey_stats"("p_city" "text", "p_state" "text", "p_program" "text", "p_teacher" "text", "p_start_date" "date", "p_end_date" "date", "p_include_total" boolean) TO "service_role";



GRANT ALL ON FUNCTION "public"."get_total_horas_aulas"("p_instrumento" "text", "p_professor" "text", "p_programa" "text", "p_patrocinador" "text", "p_turma" "text", "p_ano" integer) TO "anon";
GRANT ALL ON FUNCTION "public"."get_total_horas_aulas"("p_instrumento" "text", "p_professor" "text", "p_programa" "text", "p_patrocinador" "text", "p_turma" "text", "p_ano" integer) TO "authenticated";
GRANT ALL ON FUNCTION "public"."get_total_horas_aulas"("p_instrumento" "text", "p_professor" "text", "p_programa" "text", "p_patrocinador" "text", "p_turma" "text", "p_ano" integer) TO "service_role";



GRANT ALL ON FUNCTION "public"."handle_update_student_age"() TO "anon";
GRANT ALL ON FUNCTION "public"."handle_update_student_age"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."handle_update_student_age"() TO "service_role";



GRANT ALL ON FUNCTION "public"."insert_rel_media_survey_monitoramento_sinta_som"("p_survey_unique_id" "text", "p_urls" "text"[]) TO "anon";
GRANT ALL ON FUNCTION "public"."insert_rel_media_survey_monitoramento_sinta_som"("p_survey_unique_id" "text", "p_urls" "text"[]) TO "authenticated";
GRANT ALL ON FUNCTION "public"."insert_rel_media_survey_monitoramento_sinta_som"("p_survey_unique_id" "text", "p_urls" "text"[]) TO "service_role";



GRANT ALL ON FUNCTION "public"."normalize_pavimentacao"() TO "anon";
GRANT ALL ON FUNCTION "public"."normalize_pavimentacao"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."normalize_pavimentacao"() TO "service_role";



GRANT ALL ON FUNCTION "public"."process_rendimento_beneficios"() TO "anon";
GRANT ALL ON FUNCTION "public"."process_rendimento_beneficios"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."process_rendimento_beneficios"() TO "service_role";



GRANT ALL ON FUNCTION "public"."process_servicos_politicas"() TO "anon";
GRANT ALL ON FUNCTION "public"."process_servicos_politicas"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."process_servicos_politicas"() TO "service_role";



GRANT ALL ON FUNCTION "public"."rotate_wake_up"() TO "anon";
GRANT ALL ON FUNCTION "public"."rotate_wake_up"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."rotate_wake_up"() TO "service_role";



GRANT ALL ON FUNCTION "public"."set_modified_date"() TO "anon";
GRANT ALL ON FUNCTION "public"."set_modified_date"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."set_modified_date"() TO "service_role";



GRANT ALL ON FUNCTION "public"."students_with_birthday_on"("p_day" integer, "p_month" integer) TO "anon";
GRANT ALL ON FUNCTION "public"."students_with_birthday_on"("p_day" integer, "p_month" integer) TO "authenticated";
GRANT ALL ON FUNCTION "public"."students_with_birthday_on"("p_day" integer, "p_month" integer) TO "service_role";



GRANT ALL ON FUNCTION "public"."update_modified_date"() TO "anon";
GRANT ALL ON FUNCTION "public"."update_modified_date"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."update_modified_date"() TO "service_role";



GRANT ALL ON FUNCTION "public"."update_student_attendance_rate"() TO "anon";
GRANT ALL ON FUNCTION "public"."update_student_attendance_rate"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."update_student_attendance_rate"() TO "service_role";



GRANT ALL ON FUNCTION "public"."update_updated_at_column"() TO "anon";
GRANT ALL ON FUNCTION "public"."update_updated_at_column"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."update_updated_at_column"() TO "service_role";



GRANT ALL ON TABLE "public"."Customer Satisfaction Survey" TO "anon";
GRANT ALL ON TABLE "public"."Customer Satisfaction Survey" TO "authenticated";
GRANT ALL ON TABLE "public"."Customer Satisfaction Survey" TO "service_role";



GRANT ALL ON TABLE "public"."Customer Satisfaction Survey options" TO "anon";
GRANT ALL ON TABLE "public"."Customer Satisfaction Survey options" TO "authenticated";
GRANT ALL ON TABLE "public"."Customer Satisfaction Survey options" TO "service_role";



GRANT ALL ON SEQUENCE "public"."Customer Satisfaction Survey options_id_seq" TO "anon";
GRANT ALL ON SEQUENCE "public"."Customer Satisfaction Survey options_id_seq" TO "authenticated";
GRANT ALL ON SEQUENCE "public"."Customer Satisfaction Survey options_id_seq" TO "service_role";



GRANT ALL ON TABLE "public"."Inscrições Treinamento" TO "anon";
GRANT ALL ON TABLE "public"."Inscrições Treinamento" TO "authenticated";
GRANT ALL ON TABLE "public"."Inscrições Treinamento" TO "service_role";



GRANT ALL ON TABLE "public"."Parents" TO "anon";
GRANT ALL ON TABLE "public"."Parents" TO "authenticated";
GRANT ALL ON TABLE "public"."Parents" TO "service_role";



GRANT ALL ON TABLE "public"."Rate students" TO "anon";
GRANT ALL ON TABLE "public"."Rate students" TO "authenticated";
GRANT ALL ON TABLE "public"."Rate students" TO "service_role";



GRANT ALL ON TABLE "public"."Santander_Formularios" TO "anon";
GRANT ALL ON TABLE "public"."Santander_Formularios" TO "authenticated";
GRANT ALL ON TABLE "public"."Santander_Formularios" TO "service_role";



GRANT ALL ON TABLE "public"."Sociocultural Profile" TO "anon";
GRANT ALL ON TABLE "public"."Sociocultural Profile" TO "authenticated";
GRANT ALL ON TABLE "public"."Sociocultural Profile" TO "service_role";



GRANT ALL ON TABLE "public"."Students" TO "anon";
GRANT ALL ON TABLE "public"."Students" TO "authenticated";
GRANT ALL ON TABLE "public"."Students" TO "service_role";



GRANT ALL ON TABLE "public"."Survey_Masterclass_Sinta_Som" TO "anon";
GRANT ALL ON TABLE "public"."Survey_Masterclass_Sinta_Som" TO "authenticated";
GRANT ALL ON TABLE "public"."Survey_Masterclass_Sinta_Som" TO "service_role";



GRANT ALL ON TABLE "public"."Teachers" TO "anon";
GRANT ALL ON TABLE "public"."Teachers" TO "authenticated";
GRANT ALL ON TABLE "public"."Teachers" TO "service_role";



GRANT ALL ON TABLE "public"."app_logs" TO "anon";
GRANT ALL ON TABLE "public"."app_logs" TO "authenticated";
GRANT ALL ON TABLE "public"."app_logs" TO "service_role";



GRANT ALL ON SEQUENCE "public"."app_logs_id_seq" TO "anon";
GRANT ALL ON SEQUENCE "public"."app_logs_id_seq" TO "authenticated";
GRANT ALL ON SEQUENCE "public"."app_logs_id_seq" TO "service_role";



GRANT ALL ON TABLE "public"."attendance" TO "anon";
GRANT ALL ON TABLE "public"."attendance" TO "authenticated";
GRANT ALL ON TABLE "public"."attendance" TO "service_role";



GRANT ALL ON TABLE "public"."attendance_2024" TO "service_role";



GRANT ALL ON TABLE "public"."attendance_2025" TO "service_role";



GRANT ALL ON TABLE "public"."attendance_2026" TO "service_role";



GRANT ALL ON TABLE "public"."attendance_2027" TO "service_role";



GRANT ALL ON TABLE "public"."attendance_default" TO "service_role";



GRANT ALL ON SEQUENCE "public"."attendance_id_seq" TO "anon";
GRANT ALL ON SEQUENCE "public"."attendance_id_seq" TO "authenticated";
GRANT ALL ON SEQUENCE "public"."attendance_id_seq" TO "service_role";



GRANT ALL ON TABLE "public"."caravana_sinta_o_som" TO "anon";
GRANT ALL ON TABLE "public"."caravana_sinta_o_som" TO "authenticated";
GRANT ALL ON TABLE "public"."caravana_sinta_o_som" TO "service_role";



GRANT ALL ON TABLE "public"."class" TO "anon";
GRANT ALL ON TABLE "public"."class" TO "authenticated";
GRANT ALL ON TABLE "public"."class" TO "service_role";



GRANT ALL ON TABLE "public"."funarate_avaliacao_responsaveis" TO "anon";
GRANT ALL ON TABLE "public"."funarate_avaliacao_responsaveis" TO "authenticated";
GRANT ALL ON TABLE "public"."funarate_avaliacao_responsaveis" TO "service_role";



GRANT ALL ON TABLE "public"."funarte_avaliacao_aluno" TO "anon";
GRANT ALL ON TABLE "public"."funarte_avaliacao_aluno" TO "authenticated";
GRANT ALL ON TABLE "public"."funarte_avaliacao_aluno" TO "service_role";



GRANT ALL ON TABLE "public"."indicadores_ibme" TO "anon";
GRANT ALL ON TABLE "public"."indicadores_ibme" TO "authenticated";
GRANT ALL ON TABLE "public"."indicadores_ibme" TO "service_role";



GRANT ALL ON TABLE "public"."instrument_os" TO "anon";
GRANT ALL ON TABLE "public"."instrument_os" TO "authenticated";
GRANT ALL ON TABLE "public"."instrument_os" TO "service_role";



GRANT ALL ON SEQUENCE "public"."instrument_os_id_seq" TO "anon";
GRANT ALL ON SEQUENCE "public"."instrument_os_id_seq" TO "authenticated";
GRANT ALL ON SEQUENCE "public"."instrument_os_id_seq" TO "service_role";



GRANT ALL ON TABLE "public"."inventory" TO "anon";
GRANT ALL ON TABLE "public"."inventory" TO "authenticated";
GRANT ALL ON TABLE "public"."inventory" TO "service_role";



GRANT ALL ON TABLE "public"."parent_satisfaction_survey" TO "anon";
GRANT ALL ON TABLE "public"."parent_satisfaction_survey" TO "authenticated";
GRANT ALL ON TABLE "public"."parent_satisfaction_survey" TO "service_role";



GRANT ALL ON TABLE "public"."patrimonio" TO "anon";
GRANT ALL ON TABLE "public"."patrimonio" TO "authenticated";
GRANT ALL ON TABLE "public"."patrimonio" TO "service_role";



GRANT ALL ON TABLE "public"."program_classes" TO "anon";
GRANT ALL ON TABLE "public"."program_classes" TO "authenticated";
GRANT ALL ON TABLE "public"."program_classes" TO "service_role";



GRANT ALL ON TABLE "public"."program_instruments" TO "anon";
GRANT ALL ON TABLE "public"."program_instruments" TO "authenticated";
GRANT ALL ON TABLE "public"."program_instruments" TO "service_role";



GRANT ALL ON TABLE "public"."program_patrocinadores" TO "anon";
GRANT ALL ON TABLE "public"."program_patrocinadores" TO "authenticated";
GRANT ALL ON TABLE "public"."program_patrocinadores" TO "service_role";



GRANT ALL ON TABLE "public"."program_teachers" TO "anon";
GRANT ALL ON TABLE "public"."program_teachers" TO "authenticated";
GRANT ALL ON TABLE "public"."program_teachers" TO "service_role";



GRANT ALL ON TABLE "public"."programs" TO "anon";
GRANT ALL ON TABLE "public"."programs" TO "authenticated";
GRANT ALL ON TABLE "public"."programs" TO "service_role";



GRANT ALL ON TABLE "public"."rel_media_survey_monitoramento_sinta_som" TO "anon";
GRANT ALL ON TABLE "public"."rel_media_survey_monitoramento_sinta_som" TO "authenticated";
GRANT ALL ON TABLE "public"."rel_media_survey_monitoramento_sinta_som" TO "service_role";



GRANT ALL ON SEQUENCE "public"."rel_media_survey_monitoramento_sinta_som_id_seq" TO "anon";
GRANT ALL ON SEQUENCE "public"."rel_media_survey_monitoramento_sinta_som_id_seq" TO "authenticated";
GRANT ALL ON SEQUENCE "public"."rel_media_survey_monitoramento_sinta_som_id_seq" TO "service_role";



GRANT ALL ON TABLE "public"."relatorios_sinta_som" TO "anon";
GRANT ALL ON TABLE "public"."relatorios_sinta_som" TO "authenticated";
GRANT ALL ON TABLE "public"."relatorios_sinta_som" TO "service_role";



GRANT ALL ON TABLE "public"."schedule" TO "anon";
GRANT ALL ON TABLE "public"."schedule" TO "authenticated";
GRANT ALL ON TABLE "public"."schedule" TO "service_role";



GRANT ALL ON TABLE "public"."sinta_o_som_survey_teacher" TO "anon";
GRANT ALL ON TABLE "public"."sinta_o_som_survey_teacher" TO "authenticated";
GRANT ALL ON TABLE "public"."sinta_o_som_survey_teacher" TO "service_role";



GRANT ALL ON TABLE "public"."sponsors" TO "anon";
GRANT ALL ON TABLE "public"."sponsors" TO "authenticated";
GRANT ALL ON TABLE "public"."sponsors" TO "service_role";



GRANT ALL ON TABLE "public"."student_full_profile" TO "anon";
GRANT ALL ON TABLE "public"."student_full_profile" TO "authenticated";
GRANT ALL ON TABLE "public"."student_full_profile" TO "service_role";



GRANT ALL ON TABLE "public"."student_impact_survey" TO "anon";
GRANT ALL ON TABLE "public"."student_impact_survey" TO "authenticated";
GRANT ALL ON TABLE "public"."student_impact_survey" TO "service_role";



GRANT ALL ON SEQUENCE "public"."student_impact_survey_id_seq" TO "anon";
GRANT ALL ON SEQUENCE "public"."student_impact_survey_id_seq" TO "authenticated";
GRANT ALL ON SEQUENCE "public"."student_impact_survey_id_seq" TO "service_role";



GRANT ALL ON TABLE "public"."student_satisfaction_survey" TO "anon";
GRANT ALL ON TABLE "public"."student_satisfaction_survey" TO "authenticated";
GRANT ALL ON TABLE "public"."student_satisfaction_survey" TO "service_role";



GRANT ALL ON TABLE "public"."student_teachers_connection" TO "anon";
GRANT ALL ON TABLE "public"."student_teachers_connection" TO "authenticated";
GRANT ALL ON TABLE "public"."student_teachers_connection" TO "service_role";



GRANT ALL ON TABLE "public"."students_dob" TO "anon";
GRANT ALL ON TABLE "public"."students_dob" TO "authenticated";
GRANT ALL ON TABLE "public"."students_dob" TO "service_role";



GRANT ALL ON TABLE "public"."students_invite_code" TO "anon";
GRANT ALL ON TABLE "public"."students_invite_code" TO "authenticated";
GRANT ALL ON TABLE "public"."students_invite_code" TO "service_role";



GRANT ALL ON TABLE "public"."survey_monitoramento_sinta_som" TO "anon";
GRANT ALL ON TABLE "public"."survey_monitoramento_sinta_som" TO "authenticated";
GRANT ALL ON TABLE "public"."survey_monitoramento_sinta_som" TO "service_role";



GRANT ALL ON TABLE "public"."survey_sinta_o_som_aluno" TO "anon";
GRANT ALL ON TABLE "public"."survey_sinta_o_som_aluno" TO "authenticated";
GRANT ALL ON TABLE "public"."survey_sinta_o_som_aluno" TO "service_role";



GRANT ALL ON TABLE "public"."survey_statements" TO "anon";
GRANT ALL ON TABLE "public"."survey_statements" TO "authenticated";
GRANT ALL ON TABLE "public"."survey_statements" TO "service_role";



GRANT ALL ON SEQUENCE "public"."survey_statements_id_seq" TO "anon";
GRANT ALL ON SEQUENCE "public"."survey_statements_id_seq" TO "authenticated";
GRANT ALL ON SEQUENCE "public"."survey_statements_id_seq" TO "service_role";



GRANT ALL ON TABLE "public"."teacher_impact_survey" TO "anon";
GRANT ALL ON TABLE "public"."teacher_impact_survey" TO "authenticated";
GRANT ALL ON TABLE "public"."teacher_impact_survey" TO "service_role";



GRANT ALL ON TABLE "public"."wake_up_supabase" TO "anon";
GRANT ALL ON TABLE "public"."wake_up_supabase" TO "authenticated";
GRANT ALL ON TABLE "public"."wake_up_supabase" TO "service_role";



GRANT ALL ON SEQUENCE "public"."wake_up_supabase_id_seq" TO "anon";
GRANT ALL ON SEQUENCE "public"."wake_up_supabase_id_seq" TO "authenticated";
GRANT ALL ON SEQUENCE "public"."wake_up_supabase_id_seq" TO "service_role";



ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON SEQUENCES TO "postgres";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON SEQUENCES TO "anon";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON SEQUENCES TO "authenticated";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON SEQUENCES TO "service_role";






ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON FUNCTIONS TO "postgres";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON FUNCTIONS TO "anon";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON FUNCTIONS TO "authenticated";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON FUNCTIONS TO "service_role";






ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON TABLES TO "postgres";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON TABLES TO "anon";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON TABLES TO "authenticated";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON TABLES TO "service_role";






