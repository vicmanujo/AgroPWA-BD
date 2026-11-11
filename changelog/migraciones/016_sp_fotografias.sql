--liquibase formatted sql

--changeset victor:016-01-ux-fotografia-portada
--comment: HU-20 · Una sola foto de portada por cultivo
--preconditions onFail:HALT onError:HALT
--precondition-sql-check expectedResult:0 SELECT count(*) FROM (SELECT id_cultivo FROM fotografia WHERE es_portada GROUP BY id_cultivo HAVING count(*) > 1) AS repetidas
CREATE UNIQUE INDEX ux_fotografia_portada ON fotografia (id_cultivo) WHERE es_portada;
--rollback DROP INDEX IF EXISTS ux_fotografia_portada;

--changeset victor:016-02-sp-registrar-fotografia splitStatements:false
--comment: HU-20 · Registra una foto ya subida al almacenamiento; si el id_local ya existe devuelve la existente.
--Errores: cultivo inexistente o ajeno = no_data_found sin columna (404); avance de otro cultivo = no_data_found con COLUMN (400);
--sexta foto del avance = 55000 (409). Si es portada, la anterior deja de serlo.
CREATE OR REPLACE PROCEDURE sp_registrar_fotografia(
    p_id_usuario          INTEGER,
    p_id_cultivo          INTEGER,
    p_id_avance           INTEGER,
    p_id_local            UUID,
    p_archivo_url         VARCHAR,
    p_nombre_archivo      VARCHAR,
    p_tamano_kb           INTEGER,
    p_es_portada          BOOLEAN,
    p_latitud             NUMERIC,
    p_longitud            NUMERIC,
    INOUT p_id_fotografia INTEGER DEFAULT NULL,
    INOUT p_ya_existia    BOOLEAN DEFAULT NULL)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
    -- El dispositivo reenvió la misma foto: no se duplica
    IF p_id_local IS NOT NULL THEN
        SELECT id_fotografia INTO p_id_fotografia
        FROM fotografia
        WHERE id_usuario = p_id_usuario AND id_local = p_id_local;

        IF FOUND THEN
            p_ya_existia := TRUE;
            RETURN;
        END IF;
    END IF;

    IF NOT EXISTS (SELECT 1 FROM cultivo WHERE id_cultivo = p_id_cultivo AND id_usuario = p_id_usuario) THEN
        RAISE EXCEPTION 'Cultivo no encontrado.' USING ERRCODE = 'no_data_found';           -- 404
    END IF;

    IF p_id_avance IS NOT NULL THEN
        IF NOT EXISTS (SELECT 1 FROM avance
                       WHERE id_avance = p_id_avance AND id_cultivo = p_id_cultivo AND id_usuario = p_id_usuario) THEN
            RAISE EXCEPTION 'El avance no existe en este cultivo.'
                USING ERRCODE = 'no_data_found', COLUMN = 'id_avance';                      -- 400
        END IF;

        -- El trigger tg_fotografia_max_avance también lo impide; aquí se responde con un mensaje claro (409)
        IF (SELECT count(*) FROM fotografia WHERE id_avance = p_id_avance) >= 5 THEN
            RAISE EXCEPTION 'Un avance admite como máximo 5 fotografías.'
                USING ERRCODE = 'object_not_in_prerequisite_state';
        END IF;
    END IF;

    -- Solo una portada por cultivo (ux_fotografia_portada)
    IF p_es_portada THEN
        UPDATE fotografia SET es_portada = FALSE
        WHERE id_cultivo = p_id_cultivo AND es_portada;
    END IF;

    INSERT INTO fotografia (id_usuario, id_cultivo, id_avance, id_local, archivo_url, nombre_archivo, tamano_kb,
                            es_portada, latitud, longitud)
    VALUES (p_id_usuario, p_id_cultivo, p_id_avance, p_id_local, p_archivo_url, p_nombre_archivo, p_tamano_kb,
            coalesce(p_es_portada, FALSE), p_latitud, p_longitud)
    RETURNING id_fotografia INTO p_id_fotografia;

    p_ya_existia := FALSE;
END;
$$;
--rollback DROP PROCEDURE IF EXISTS sp_registrar_fotografia(INTEGER, INTEGER, INTEGER, UUID, VARCHAR, VARCHAR, INTEGER, BOOLEAN, NUMERIC, NUMERIC, INTEGER, BOOLEAN);

--changeset victor:016-03-sp-obtener-fotografia splitStatements:false
--comment: HU-20 · Una foto del usuario (respuesta de la subida); sin fila si no es suya. archivo_url es la ruta en el almacenamiento
CREATE OR REPLACE PROCEDURE sp_obtener_fotografia(
    p_id_fotografia    INTEGER,
    p_id_usuario       INTEGER,
    INOUT p_resultado  REFCURSOR DEFAULT 'resultado')
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
    OPEN p_resultado FOR
        SELECT id_fotografia, id_local, id_cultivo, id_avance, archivo_url, nombre_archivo, tamano_kb,
               es_portada, latitud, longitud, fecha_captura
        FROM fotografia
        WHERE id_fotografia = p_id_fotografia
          AND id_usuario = p_id_usuario;
END;
$$;
--rollback DROP PROCEDURE IF EXISTS sp_obtener_fotografia(INTEGER, INTEGER, REFCURSOR);

--changeset victor:016-04-sp-eliminar-fotografia splitStatements:false
--comment: HU-20 · Elimina una foto del usuario y devuelve su ruta para borrar el archivo; NULL si no existe o no es suya (404)
CREATE OR REPLACE PROCEDURE sp_eliminar_fotografia(
    p_id_fotografia     INTEGER,
    p_id_usuario        INTEGER,
    INOUT p_archivo_url VARCHAR DEFAULT NULL)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
    DELETE FROM fotografia
    WHERE id_fotografia = p_id_fotografia AND id_usuario = p_id_usuario
    RETURNING archivo_url INTO p_archivo_url;
END;
$$;
--rollback DROP PROCEDURE IF EXISTS sp_eliminar_fotografia(INTEGER, INTEGER, VARCHAR);
