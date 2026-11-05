--liquibase formatted sql

--changeset victor:014-01-sp-editar-cultivo splitStatements:false
--comment: HU-17 · Edita un cultivo del usuario; p_existe = false si no existe o no es suyo (404) y p_actualizado = false si el cambio es más viejo que el guardado
CREATE OR REPLACE PROCEDURE sp_editar_cultivo(
    p_id_cultivo          INTEGER,
    p_id_usuario          INTEGER,
    p_id_parcela          INTEGER,
    p_id_tipo_cultivo     INTEGER,
    p_nombre              VARCHAR,
    p_variedad            VARCHAR,
    p_fecha_siembra       DATE,
    p_estado              VARCHAR,
    p_fecha_cosecha       DATE,
    p_observaciones       VARCHAR,
    p_fecha_modificacion  TIMESTAMPTZ DEFAULT NULL,
    INOUT p_existe        BOOLEAN DEFAULT NULL,
    INOUT p_actualizado   BOOLEAN DEFAULT NULL)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    v_actual cultivo%ROWTYPE;
BEGIN
    SELECT * INTO v_actual
    FROM cultivo
    WHERE id_cultivo = p_id_cultivo AND id_usuario = p_id_usuario;

    IF NOT FOUND THEN
        p_existe := FALSE;        -- la API responde 404
        p_actualizado := FALSE;
        RETURN;
    END IF;

    p_existe := TRUE;

    -- Cambio hecho sin conexión y más viejo que el guardado: se conserva el más reciente
    IF p_fecha_modificacion IS NOT NULL AND p_fecha_modificacion < v_actual.fecha_actualizacion THEN
        p_actualizado := FALSE;
        RETURN;
    END IF;

    -- La parcela y el tipo se validan como al registrar; se aceptan los que ya tenía aunque se hayan desactivado
    IF p_id_parcela <> v_actual.id_parcela
       AND NOT EXISTS (SELECT 1 FROM parcela
                       WHERE id_parcela = p_id_parcela AND id_usuario = p_id_usuario AND activo) THEN
        RAISE EXCEPTION 'La parcela no existe.'
            USING ERRCODE = 'no_data_found', COLUMN = 'id_parcela';
    END IF;

    IF p_id_tipo_cultivo <> v_actual.id_tipo_cultivo
       AND NOT EXISTS (SELECT 1 FROM tipo_cultivo WHERE id_tipo_cultivo = p_id_tipo_cultivo AND activo) THEN
        RAISE EXCEPTION 'El tipo de cultivo no es válido.'
            USING ERRCODE = 'no_data_found', COLUMN = 'id_tipo_cultivo';
    END IF;

    -- fecha_actualizacion la llena el trigger tg_cultivo_actualizacion
    UPDATE cultivo
    SET id_parcela            = p_id_parcela,
        id_tipo_cultivo       = p_id_tipo_cultivo,
        nombre                = trim(p_nombre),
        variedad              = nullif(trim(p_variedad), ''),
        fecha_siembra         = p_fecha_siembra,
        estado                = lower(trim(p_estado)),
        -- La fecha de cosecha solo aplica a los cultivos finalizados
        fecha_cosecha         = CASE WHEN lower(trim(p_estado)) = 'finalizado' THEN p_fecha_cosecha END,
        observaciones         = nullif(trim(p_observaciones), ''),
        estado_sincronizacion = 'sincronizado'
    WHERE id_cultivo = p_id_cultivo AND id_usuario = p_id_usuario;

    p_actualizado := TRUE;
END;
$$;
--rollback DROP PROCEDURE IF EXISTS sp_editar_cultivo(INTEGER, INTEGER, INTEGER, INTEGER, VARCHAR, VARCHAR, DATE, VARCHAR, DATE, VARCHAR, TIMESTAMPTZ, BOOLEAN, BOOLEAN);

--changeset victor:014-02-sp-eliminar-cultivo splitStatements:false
--comment: HU-18 · Elimina un cultivo del usuario con sus avances y fotografías (ON DELETE CASCADE); p_eliminado = false si no existe o no es suyo (404)
CREATE OR REPLACE PROCEDURE sp_eliminar_cultivo(
    p_id_cultivo        INTEGER,
    p_id_usuario        INTEGER,
    INOUT p_eliminado   BOOLEAN DEFAULT NULL)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
    DELETE FROM cultivo
    WHERE id_cultivo = p_id_cultivo AND id_usuario = p_id_usuario;

    p_eliminado := FOUND;
END;
$$;
--rollback DROP PROCEDURE IF EXISTS sp_eliminar_cultivo(INTEGER, INTEGER, BOOLEAN);

--changeset victor:014-03-ix-mensaje-contacto-correo
--comment: HU-28 · Índice para contar rápido los envíos de un correo en la última hora
CREATE INDEX ix_mensaje_contacto_correo_fecha ON mensaje_contacto (lower(correo), fecha_envio);
--rollback DROP INDEX IF EXISTS ix_mensaje_contacto_correo_fecha;

--changeset victor:014-04-sp-registrar-mensaje-contacto splitStatements:false
--comment: HU-28 · Guarda un mensaje de contacto; p_limite_excedido = true si el correo ya envió 3 en la última hora (429)
CREATE OR REPLACE PROCEDURE sp_registrar_mensaje_contacto(
    p_nombre                 VARCHAR,
    p_correo                 VARCHAR,
    p_asunto                 VARCHAR,
    p_mensaje                VARCHAR,
    p_maximo_por_hora        INTEGER DEFAULT 3,
    INOUT p_id_mensaje       INTEGER DEFAULT NULL,
    INOUT p_limite_excedido  BOOLEAN DEFAULT NULL)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
    IF (SELECT count(*) FROM mensaje_contacto
        WHERE lower(correo) = lower(trim(p_correo))
          AND fecha_envio > now() - INTERVAL '1 hour') >= p_maximo_por_hora THEN
        p_limite_excedido := TRUE;
        RETURN;
    END IF;

    INSERT INTO mensaje_contacto (nombre, correo, asunto, mensaje)
    VALUES (trim(p_nombre), lower(trim(p_correo)), nullif(trim(p_asunto), ''), trim(p_mensaje))
    RETURNING id_mensaje INTO p_id_mensaje;

    p_limite_excedido := FALSE;
END;
$$;
--rollback DROP PROCEDURE IF EXISTS sp_registrar_mensaje_contacto(VARCHAR, VARCHAR, VARCHAR, VARCHAR, INTEGER, INTEGER, BOOLEAN);

--changeset victor:014-05-sp-obtener-detalle-cultivo-fecha-actualizacion splitStatements:false rollbackSplitStatements:false
--comment: HU-17 · El detalle incluye fecha_actualizacion (última modificación que muestra el formulario de edición)
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
               c.estado, c.estado_sincronizacion, c.observaciones, c.fecha_actualizacion,
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
--rollback CREATE OR REPLACE PROCEDURE sp_obtener_detalle_cultivo(
--rollback     p_id_cultivo       INTEGER,
--rollback     p_id_usuario       INTEGER,
--rollback     p_zona_horaria     VARCHAR DEFAULT 'America/Mexico_City',
--rollback     INOUT p_resultado  REFCURSOR DEFAULT 'resultado')
--rollback LANGUAGE plpgsql
--rollback SECURITY DEFINER
--rollback SET search_path = public
--rollback AS $$
--rollback DECLARE
--rollback     v_hoy DATE := (now() AT TIME ZONE p_zona_horaria)::DATE;
--rollback BEGIN
--rollback     OPEN p_resultado FOR
--rollback         SELECT c.id_cultivo, c.id_local, c.nombre,
--rollback                c.id_tipo_cultivo, tc.nombre AS tipo, c.variedad,
--rollback                c.id_parcela, p.nombre AS parcela, p.superficie_ha,
--rollback                c.fecha_siembra, c.fecha_cosecha, (v_hoy - c.fecha_siembra) AS dias_cultivo,
--rollback                c.estado, c.estado_sincronizacion, c.observaciones,
--rollback                (SELECT f.archivo_url FROM fotografia f
--rollback                  WHERE f.id_cultivo = c.id_cultivo AND f.es_portada
--rollback                  ORDER BY f.fecha_captura DESC LIMIT 1)                            AS portada_url,
--rollback                (SELECT count(*) FROM avance a WHERE a.id_cultivo = c.id_cultivo)::INTEGER     AS total_avances,
--rollback                (SELECT count(*) FROM fotografia f WHERE f.id_cultivo = c.id_cultivo)::INTEGER AS total_fotografias
--rollback         FROM cultivo c
--rollback         JOIN tipo_cultivo tc ON tc.id_tipo_cultivo = c.id_tipo_cultivo
--rollback         JOIN parcela p       ON p.id_parcela = c.id_parcela
--rollback         WHERE c.id_cultivo = p_id_cultivo
--rollback           AND c.id_usuario = p_id_usuario;
--rollback END;
--rollback $$;
