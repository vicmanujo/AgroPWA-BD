--liquibase formatted sql

--changeset victor:013-01-sp-obtener-tipos-cultivo splitStatements:false
--comment: HU-14 · Catálogo de tipos de cultivo activos (selector del formulario)
CREATE OR REPLACE PROCEDURE sp_obtener_tipos_cultivo(
    INOUT p_resultado  REFCURSOR DEFAULT 'resultado')
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
    OPEN p_resultado FOR
        SELECT id_tipo_cultivo, nombre
        FROM tipo_cultivo
        WHERE activo
        ORDER BY id_tipo_cultivo;   -- el orden del catálogo deja «Otro» al final
END;
$$;
--rollback DROP PROCEDURE IF EXISTS sp_obtener_tipos_cultivo(REFCURSOR);

--changeset victor:013-02-sp-registrar-cultivo splitStatements:false
--comment: HU-14 · Registra un cultivo activo en una parcela del usuario; si el id_local ya existe devuelve el existente
CREATE OR REPLACE PROCEDURE sp_registrar_cultivo(
    p_id_usuario        INTEGER,
    p_id_local          UUID,
    p_id_parcela        INTEGER,
    p_id_tipo_cultivo   INTEGER,
    p_nombre            VARCHAR,
    p_variedad          VARCHAR,
    p_fecha_siembra     DATE,
    p_observaciones     VARCHAR,
    INOUT p_id_cultivo  INTEGER DEFAULT NULL,
    INOUT p_ya_existia  BOOLEAN DEFAULT NULL)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
    -- El dispositivo reenvió el mismo cultivo: no se duplica
    IF p_id_local IS NOT NULL THEN
        SELECT id_cultivo INTO p_id_cultivo
        FROM cultivo
        WHERE id_usuario = p_id_usuario AND id_local = p_id_local;

        IF FOUND THEN
            p_ya_existia := TRUE;
            RETURN;
        END IF;
    END IF;

    -- La parcela debe ser del usuario y estar activa (COLUMN indica el campo a la API)
    IF NOT EXISTS (SELECT 1 FROM parcela
                   WHERE id_parcela = p_id_parcela AND id_usuario = p_id_usuario AND activo) THEN
        RAISE EXCEPTION 'La parcela no existe.'
            USING ERRCODE = 'no_data_found', COLUMN = 'id_parcela';
    END IF;

    IF NOT EXISTS (SELECT 1 FROM tipo_cultivo WHERE id_tipo_cultivo = p_id_tipo_cultivo AND activo) THEN
        RAISE EXCEPTION 'El tipo de cultivo no es válido.'
            USING ERRCODE = 'no_data_found', COLUMN = 'id_tipo_cultivo';
    END IF;

    -- Todo cultivo nuevo inicia «activo» (valor por defecto de la tabla)
    INSERT INTO cultivo (id_usuario, id_parcela, id_tipo_cultivo, id_local, nombre, variedad,
                         fecha_siembra, observaciones)
    VALUES (p_id_usuario, p_id_parcela, p_id_tipo_cultivo, p_id_local, trim(p_nombre),
            nullif(trim(p_variedad), ''), p_fecha_siembra, nullif(trim(p_observaciones), ''))
    RETURNING id_cultivo INTO p_id_cultivo;

    p_ya_existia := FALSE;
END;
$$;
--rollback DROP PROCEDURE IF EXISTS sp_registrar_cultivo(INTEGER, UUID, INTEGER, INTEGER, VARCHAR, VARCHAR, DATE, VARCHAR, INTEGER, BOOLEAN);

--changeset victor:013-03-sp-obtener-cultivos splitStatements:false
--comment: HU-15 · Cultivos del usuario con búsqueda (cultivo o parcela, sin acentos), filtros, orden y paginación
CREATE OR REPLACE PROCEDURE sp_obtener_cultivos(
    p_id_usuario       INTEGER,
    p_buscar           VARCHAR,
    p_estado           VARCHAR,
    p_id_tipo_cultivo  INTEGER,
    p_pagina           INTEGER DEFAULT 1,
    p_tamano           INTEGER DEFAULT 20,
    p_zona_horaria     VARCHAR DEFAULT 'America/Mexico_City',
    INOUT p_resultado  REFCURSOR DEFAULT 'resultado')
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    v_hoy    DATE    := (now() AT TIME ZONE p_zona_horaria)::DATE;
    v_tamano INTEGER := least(greatest(coalesce(p_tamano, 20), 1), 50);
    v_pagina INTEGER := greatest(coalesce(p_pagina, 1), 1);
    -- Búsqueda sin mayúsculas ni acentos: «maiz» encuentra «Maíz criollo»
    v_buscar VARCHAR := nullif(translate(lower(trim(p_buscar)), 'áéíóúüñ', 'aeiouun'), '');
BEGIN
    OPEN p_resultado FOR
        SELECT c.id_cultivo, c.id_local, c.nombre,
               tc.nombre AS tipo, p.nombre AS parcela,
               c.fecha_siembra, (v_hoy - c.fecha_siembra) AS dias_cultivo,
               c.estado, c.estado_sincronizacion,
               (SELECT f.archivo_url FROM fotografia f
                 WHERE f.id_cultivo = c.id_cultivo AND f.es_portada
                 ORDER BY f.fecha_captura DESC LIMIT 1) AS portada_url,
               count(*) OVER ()::INTEGER AS total          -- total sin paginar (para el paginador)
        FROM cultivo c
        JOIN tipo_cultivo tc ON tc.id_tipo_cultivo = c.id_tipo_cultivo
        JOIN parcela p       ON p.id_parcela = c.id_parcela
        WHERE c.id_usuario = p_id_usuario
          AND (p_estado IS NULL OR c.estado = p_estado)
          AND (p_id_tipo_cultivo IS NULL OR c.id_tipo_cultivo = p_id_tipo_cultivo)
          AND (v_buscar IS NULL
               OR translate(lower(c.nombre), 'áéíóúüñ', 'aeiouun') LIKE '%' || v_buscar || '%'
               OR translate(lower(p.nombre), 'áéíóúüñ', 'aeiouun') LIKE '%' || v_buscar || '%')
        ORDER BY c.fecha_creacion DESC, c.id_cultivo DESC   -- del más reciente al más antiguo
        LIMIT v_tamano OFFSET (v_pagina - 1) * v_tamano;
END;
$$;
--rollback DROP PROCEDURE IF EXISTS sp_obtener_cultivos(INTEGER, VARCHAR, VARCHAR, INTEGER, INTEGER, INTEGER, VARCHAR, REFCURSOR);

--changeset victor:013-04-sp-obtener-detalle-cultivo splitStatements:false
--comment: HU-16 · Datos de un cultivo del usuario con sus totales; sin fila si no existe o es de otro usuario (404)
CREATE OR REPLACE PROCEDURE sp_obtener_detalle_cultivo(
    p_id_cultivo       INTEGER,
    p_id_usuario       INTEGER,
    p_zona_horaria     VARCHAR DEFAULT 'America/Mexico_City',
    INOUT p_resultado  REFCURSOR DEFAULT 'resultado')
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    v_hoy DATE := (now() AT TIME ZONE p_zona_horaria)::DATE;
BEGIN
    OPEN p_resultado FOR
        SELECT c.id_cultivo, c.id_local, c.nombre,
               c.id_tipo_cultivo, tc.nombre AS tipo, c.variedad,
               c.id_parcela, p.nombre AS parcela, p.superficie_ha,
               c.fecha_siembra, c.fecha_cosecha, (v_hoy - c.fecha_siembra) AS dias_cultivo,
               c.estado, c.estado_sincronizacion, c.observaciones,
               (SELECT f.archivo_url FROM fotografia f
                 WHERE f.id_cultivo = c.id_cultivo AND f.es_portada
                 ORDER BY f.fecha_captura DESC LIMIT 1)                            AS portada_url,
               (SELECT count(*) FROM avance a WHERE a.id_cultivo = c.id_cultivo)::INTEGER     AS total_avances,
               (SELECT count(*) FROM fotografia f WHERE f.id_cultivo = c.id_cultivo)::INTEGER AS total_fotografias
        FROM cultivo c
        JOIN tipo_cultivo tc ON tc.id_tipo_cultivo = c.id_tipo_cultivo
        JOIN parcela p       ON p.id_parcela = c.id_parcela
        WHERE c.id_cultivo = p_id_cultivo
          AND c.id_usuario = p_id_usuario;
END;
$$;
--rollback DROP PROCEDURE IF EXISTS sp_obtener_detalle_cultivo(INTEGER, INTEGER, VARCHAR, REFCURSOR);

--changeset victor:013-05-sp-obtener-avances-cultivo splitStatements:false
--comment: HU-16 · Avances de un cultivo del usuario, del más reciente al más antiguo, con su número de fotos
CREATE OR REPLACE PROCEDURE sp_obtener_avances_cultivo(
    p_id_cultivo       INTEGER,
    p_id_usuario       INTEGER,
    INOUT p_resultado  REFCURSOR DEFAULT 'resultado')
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
    OPEN p_resultado FOR
        SELECT a.id_avance, ta.nombre AS tipo, a.fecha_actividad, a.descripcion,
               (SELECT count(*) FROM fotografia f WHERE f.id_avance = a.id_avance)::INTEGER AS fotos
        FROM avance a
        JOIN tipo_actividad ta ON ta.id_tipo_actividad = a.id_tipo_actividad
        WHERE a.id_cultivo = p_id_cultivo
          AND a.id_usuario = p_id_usuario
        ORDER BY a.fecha_actividad DESC, a.id_avance DESC;
END;
$$;
--rollback DROP PROCEDURE IF EXISTS sp_obtener_avances_cultivo(INTEGER, INTEGER, REFCURSOR);

--changeset victor:013-06-sp-obtener-fotografias-cultivo splitStatements:false
--comment: HU-16 · Fotografías de un cultivo del usuario (galería), de la más reciente a la más antigua
CREATE OR REPLACE PROCEDURE sp_obtener_fotografias_cultivo(
    p_id_cultivo       INTEGER,
    p_id_usuario       INTEGER,
    INOUT p_resultado  REFCURSOR DEFAULT 'resultado')
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
    OPEN p_resultado FOR
        SELECT f.id_fotografia, f.archivo_url, f.fecha_captura, f.es_portada, f.id_avance
        FROM fotografia f
        WHERE f.id_cultivo = p_id_cultivo
          AND f.id_usuario = p_id_usuario
        ORDER BY f.fecha_captura DESC, f.id_fotografia DESC;
END;
$$;
--rollback DROP PROCEDURE IF EXISTS sp_obtener_fotografias_cultivo(INTEGER, INTEGER, REFCURSOR);
