--liquibase formatted sql

--changeset victor:017-01-sp-registrar-dispositivo splitStatements:false
--comment: HU-22 · Registra el dispositivo (PWA) del usuario; si el identificador ya existe devuelve el mismo y actualiza su nombre
CREATE OR REPLACE PROCEDURE sp_registrar_dispositivo(
    p_id_usuario            INTEGER,
    p_identificador         VARCHAR,
    p_nombre                VARCHAR,
    INOUT p_id_dispositivo  INTEGER DEFAULT NULL,
    INOUT p_ya_existia      BOOLEAN DEFAULT NULL)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
    UPDATE dispositivo
    SET nombre = trim(p_nombre)
    WHERE id_usuario = p_id_usuario AND identificador = trim(p_identificador)
    RETURNING id_dispositivo INTO p_id_dispositivo;

    IF FOUND THEN
        p_ya_existia := TRUE;
        RETURN;
    END IF;

    INSERT INTO dispositivo (id_usuario, identificador, nombre)
    VALUES (p_id_usuario, trim(p_identificador), trim(p_nombre))
    RETURNING id_dispositivo INTO p_id_dispositivo;

    p_ya_existia := FALSE;
END;
$$;
--rollback DROP PROCEDURE IF EXISTS sp_registrar_dispositivo(INTEGER, VARCHAR, VARCHAR, INTEGER, BOOLEAN);

--changeset victor:017-02-sp-actualizar-preferencias-dispositivo splitStatements:false
--comment: HU-22 · «Sincronizar automáticamente», «Solo con Wi-Fi» y espacio usado; p_actualizado = false si el dispositivo no es del usuario (404)
CREATE OR REPLACE PROCEDURE sp_actualizar_preferencias_dispositivo(
    p_id_dispositivo     INTEGER,
    p_id_usuario         INTEGER,
    p_sincronizar_auto   BOOLEAN,
    p_solo_wifi          BOOLEAN,
    p_espacio_usado_mb   NUMERIC,
    INOUT p_actualizado  BOOLEAN DEFAULT NULL)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
    UPDATE dispositivo
    SET sincronizar_auto = p_sincronizar_auto,
        solo_wifi        = p_solo_wifi,
        espacio_usado_mb = coalesce(p_espacio_usado_mb, espacio_usado_mb)   -- opcional
    WHERE id_dispositivo = p_id_dispositivo AND id_usuario = p_id_usuario;

    p_actualizado := FOUND;
END;
$$;
--rollback DROP PROCEDURE IF EXISTS sp_actualizar_preferencias_dispositivo(INTEGER, INTEGER, BOOLEAN, BOOLEAN, NUMERIC, BOOLEAN);

--changeset victor:017-03-sp-obtener-estado-sincronizacion splitStatements:false
--comment: HU-22 · Estado de la pantalla «Sincronización» de un dispositivo del usuario; sin fila si no es suyo (404)
CREATE OR REPLACE PROCEDURE sp_obtener_estado_sincronizacion(
    p_id_dispositivo   INTEGER,
    p_id_usuario       INTEGER,
    INOUT p_resultado  REFCURSOR DEFAULT 'resultado')
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
    OPEN p_resultado FOR
        SELECT d.id_dispositivo, d.nombre, d.sincronizar_auto, d.solo_wifi, d.espacio_usado_mb,
               d.ultima_sincronizacion,
               (SELECT count(*) FROM cola_sincronizacion c
                 WHERE c.id_dispositivo = d.id_dispositivo AND c.estado = 'error')::INTEGER AS errores
        FROM dispositivo d
        WHERE d.id_dispositivo = p_id_dispositivo
          AND d.id_usuario = p_id_usuario;
END;
$$;
--rollback DROP PROCEDURE IF EXISTS sp_obtener_estado_sincronizacion(INTEGER, INTEGER, REFCURSOR);

--changeset victor:017-04-ix-cola-dispositivo-local
--comment: HU-22 · Búsqueda de una operación de la cola por dispositivo, registro local y operación (reintentos)
CREATE INDEX ix_cola_dispositivo_local ON cola_sincronizacion (id_dispositivo, id_local, operacion);
--rollback DROP INDEX IF EXISTS ix_cola_dispositivo_local;

--changeset victor:017-05-sp-registrar-resultado-sincronizacion splitStatements:false
--comment: HU-22 · Guarda en la cola el resultado de una operación; si ya se había intentado, suma un intento
CREATE OR REPLACE PROCEDURE sp_registrar_resultado_sincronizacion(
    p_id_usuario       INTEGER,
    p_id_dispositivo   INTEGER,
    p_entidad          VARCHAR,
    p_id_local         UUID,
    p_operacion        VARCHAR,
    p_datos_json       JSONB,
    p_estado           VARCHAR,
    p_mensaje_error    VARCHAR)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
    UPDATE cola_sincronizacion
    SET datos_json           = p_datos_json,
        estado               = p_estado,
        intentos             = intentos + 1,
        mensaje_error        = left(p_mensaje_error, 300),
        fecha_sincronizacion = CASE WHEN p_estado = 'sincronizado' THEN now() END
    WHERE id_dispositivo = p_id_dispositivo AND id_usuario = p_id_usuario
      AND id_local = p_id_local AND operacion = p_operacion;

    IF NOT FOUND THEN
        INSERT INTO cola_sincronizacion (id_usuario, id_dispositivo, entidad, id_local, operacion, datos_json,
                                         estado, intentos, mensaje_error, fecha_sincronizacion)
        VALUES (p_id_usuario, p_id_dispositivo, p_entidad, p_id_local, p_operacion, p_datos_json,
                p_estado, 1, left(p_mensaje_error, 300),
                CASE WHEN p_estado = 'sincronizado' THEN now() END);
    END IF;
END;
$$;
--rollback DROP PROCEDURE IF EXISTS sp_registrar_resultado_sincronizacion(INTEGER, INTEGER, VARCHAR, UUID, VARCHAR, JSONB, VARCHAR, VARCHAR);

--changeset victor:017-06-sp-marcar-sincronizacion-dispositivo splitStatements:false
--comment: HU-22 · Actualiza la última sincronización del dispositivo al terminar un lote
CREATE OR REPLACE PROCEDURE sp_marcar_sincronizacion_dispositivo(
    p_id_dispositivo   INTEGER,
    p_id_usuario       INTEGER)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
    UPDATE dispositivo
    SET ultima_sincronizacion = now()
    WHERE id_dispositivo = p_id_dispositivo AND id_usuario = p_id_usuario;
END;
$$;
--rollback DROP PROCEDURE IF EXISTS sp_marcar_sincronizacion_dispositivo(INTEGER, INTEGER);

--changeset victor:017-07-sp-obtener-id-por-local splitStatements:false
--comment: HU-22 · Traduce el id_local de un registro del usuario a su id del servidor; NULL si no existe
CREATE OR REPLACE PROCEDURE sp_obtener_id_por_local(
    p_id_usuario   INTEGER,
    p_entidad      VARCHAR,
    p_id_local     UUID,
    INOUT p_id     INTEGER DEFAULT NULL)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
    p_id := CASE p_entidad
        WHEN 'parcela'    THEN (SELECT id_parcela    FROM parcela    WHERE id_usuario = p_id_usuario AND id_local = p_id_local)
        WHEN 'cultivo'    THEN (SELECT id_cultivo    FROM cultivo    WHERE id_usuario = p_id_usuario AND id_local = p_id_local)
        WHEN 'avance'     THEN (SELECT id_avance     FROM avance     WHERE id_usuario = p_id_usuario AND id_local = p_id_local)
        WHEN 'fotografia' THEN (SELECT id_fotografia FROM fotografia WHERE id_usuario = p_id_usuario AND id_local = p_id_local)
    END;
END;
$$;
--rollback DROP PROCEDURE IF EXISTS sp_obtener_id_por_local(INTEGER, VARCHAR, UUID, INTEGER);
