--liquibase formatted sql

--changeset victor:015-01-sp-obtener-tipos-actividad splitStatements:false
--comment: HU-19 · Catálogo de tipos de actividad activos (selector del formulario de avance)
CREATE OR REPLACE PROCEDURE sp_obtener_tipos_actividad(
    INOUT p_resultado  REFCURSOR DEFAULT 'resultado')
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
    OPEN p_resultado FOR
        SELECT id_tipo_actividad, nombre
        FROM tipo_actividad
        WHERE activo
        ORDER BY id_tipo_actividad;   -- el orden del catálogo deja «Otra» al final
END;
$$;
--rollback DROP PROCEDURE IF EXISTS sp_obtener_tipos_actividad(REFCURSOR);

--changeset victor:015-02-sp-registrar-avance splitStatements:false
--comment: HU-19 · Registra un avance en un cultivo activo del usuario; si el id_local ya existe devuelve el existente.
--Errores: cultivo inexistente o ajeno = no_data_found sin columna (404); cultivo no activo = 55000 (409);
--dato inválido = no_data_found o invalid_parameter_value con COLUMN (400 en ese campo)
CREATE OR REPLACE PROCEDURE sp_registrar_avance(
    p_id_usuario         INTEGER,
    p_id_cultivo         INTEGER,
    p_id_local           UUID,
    p_id_tipo_actividad  INTEGER,
    p_fecha_actividad    TIMESTAMPTZ,
    p_descripcion        VARCHAR,
    p_duracion_min       INTEGER,
    p_metodo_riego       VARCHAR,
    p_producto           VARCHAR,
    p_cantidad           NUMERIC,
    p_unidad             VARCHAR,
    p_zona_horaria       VARCHAR DEFAULT 'America/Mexico_City',
    INOUT p_id_avance    INTEGER DEFAULT NULL,
    INOUT p_ya_existia   BOOLEAN DEFAULT NULL)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    v_cultivo  cultivo%ROWTYPE;
    v_tipo     VARCHAR;
BEGIN
    -- El dispositivo reenvió el mismo avance: no se duplica
    IF p_id_local IS NOT NULL THEN
        SELECT id_avance INTO p_id_avance
        FROM avance
        WHERE id_usuario = p_id_usuario AND id_local = p_id_local;

        IF FOUND THEN
            p_ya_existia := TRUE;
            RETURN;
        END IF;
    END IF;

    SELECT * INTO v_cultivo
    FROM cultivo
    WHERE id_cultivo = p_id_cultivo AND id_usuario = p_id_usuario;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Cultivo no encontrado.' USING ERRCODE = 'no_data_found';   -- 404
    END IF;

    IF v_cultivo.estado <> 'activo' THEN
        RAISE EXCEPTION 'Solo se pueden registrar avances en cultivos activos.'
            USING ERRCODE = 'object_not_in_prerequisite_state';                      -- 409
    END IF;

    SELECT lower(nombre) INTO v_tipo
    FROM tipo_actividad
    WHERE id_tipo_actividad = p_id_tipo_actividad AND activo;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'El tipo de actividad no es válido.'
            USING ERRCODE = 'no_data_found', COLUMN = 'id_tipo_actividad';
    END IF;

    -- La fecha de siembra es un día calendario: se compara con el día de la actividad en México
    IF (p_fecha_actividad AT TIME ZONE p_zona_horaria)::DATE < v_cultivo.fecha_siembra THEN
        RAISE EXCEPTION 'La fecha no puede ser anterior a la siembra.'
            USING ERRCODE = 'invalid_parameter_value', COLUMN = 'fecha_actividad';
    END IF;

    -- Campos según el tipo (se decide por el nombre, no por el id)
    IF v_tipo = 'riego' THEN
        IF p_duracion_min IS NULL THEN
            RAISE EXCEPTION 'Captura la duración del riego en minutos.'
                USING ERRCODE = 'invalid_parameter_value', COLUMN = 'duracion_min';
        END IF;
        IF nullif(trim(p_metodo_riego), '') IS NULL THEN
            RAISE EXCEPTION 'Captura el método de riego.'
                USING ERRCODE = 'invalid_parameter_value', COLUMN = 'metodo_riego';
        END IF;
    ELSIF v_tipo = 'fertilización' THEN
        IF nullif(trim(p_producto), '') IS NULL THEN
            RAISE EXCEPTION 'Captura el producto aplicado.'
                USING ERRCODE = 'invalid_parameter_value', COLUMN = 'producto';
        END IF;
        IF p_cantidad IS NULL THEN
            RAISE EXCEPTION 'Captura la cantidad aplicada.'
                USING ERRCODE = 'invalid_parameter_value', COLUMN = 'cantidad';
        END IF;
        IF nullif(trim(p_unidad), '') IS NULL THEN
            RAISE EXCEPTION 'Captura la unidad (kg, L, bultos…).'
                USING ERRCODE = 'invalid_parameter_value', COLUMN = 'unidad';
        END IF;
    END IF;

    -- Los campos que no aplican al tipo se guardan vacíos
    INSERT INTO avance (id_cultivo, id_tipo_actividad, id_usuario, id_local, fecha_actividad, descripcion,
                        duracion_min, metodo_riego, producto, cantidad, unidad)
    VALUES (p_id_cultivo, p_id_tipo_actividad, p_id_usuario, p_id_local, p_fecha_actividad, trim(p_descripcion),
            CASE WHEN v_tipo = 'riego' THEN p_duracion_min END,
            CASE WHEN v_tipo = 'riego' THEN trim(p_metodo_riego) END,
            CASE WHEN v_tipo = 'fertilización' THEN trim(p_producto) END,
            CASE WHEN v_tipo = 'fertilización' THEN p_cantidad END,
            CASE WHEN v_tipo = 'fertilización' THEN trim(p_unidad) END)
    RETURNING id_avance INTO p_id_avance;

    p_ya_existia := FALSE;
END;
$$;
--rollback DROP PROCEDURE IF EXISTS sp_registrar_avance(INTEGER, INTEGER, UUID, INTEGER, TIMESTAMPTZ, VARCHAR, INTEGER, VARCHAR, VARCHAR, NUMERIC, VARCHAR, VARCHAR, INTEGER, BOOLEAN);

--changeset victor:015-03-sp-obtener-avance splitStatements:false
--comment: HU-19 · Un avance del usuario con el nombre de su tipo (respuesta del registro); sin fila si no es suyo
CREATE OR REPLACE PROCEDURE sp_obtener_avance(
    p_id_avance        INTEGER,
    p_id_usuario       INTEGER,
    INOUT p_resultado  REFCURSOR DEFAULT 'resultado')
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
    OPEN p_resultado FOR
        SELECT a.id_avance, a.id_local, a.id_cultivo, a.id_tipo_actividad, ta.nombre AS tipo,
               a.fecha_actividad, a.descripcion, a.duracion_min, a.metodo_riego,
               a.producto, a.cantidad, a.unidad, a.estado_sincronizacion
        FROM avance a
        JOIN tipo_actividad ta ON ta.id_tipo_actividad = a.id_tipo_actividad
        WHERE a.id_avance = p_id_avance
          AND a.id_usuario = p_id_usuario;
END;
$$;
--rollback DROP PROCEDURE IF EXISTS sp_obtener_avance(INTEGER, INTEGER, REFCURSOR);
