--liquibase formatted sql

--changeset victor:018-01-sp-obtener-perfil splitStatements:false
--comment: HU-26 · Datos del perfil del usuario (con el nombre de su rol); sin fila si no existe o está dado de baja (404)
CREATE OR REPLACE PROCEDURE sp_obtener_perfil(
    p_id_usuario       INTEGER,
    INOUT p_resultado  REFCURSOR DEFAULT 'resultado')
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
    OPEN p_resultado FOR
        SELECT u.nombre, u.apellido_paterno, u.apellido_materno, u.correo, u.telefono,
               u.comunidad_municipio, r.nombre AS rol, u.fecha_registro
        FROM usuario u
        JOIN rol r ON r.id_rol = u.id_rol
        WHERE u.id_usuario = p_id_usuario
          AND u.activo;
END;
$$;
--rollback DROP PROCEDURE IF EXISTS sp_obtener_perfil(INTEGER, REFCURSOR);

--changeset victor:018-02-sp-actualizar-perfil splitStatements:false
--comment: HU-26 · Actualiza nombre, apellidos, teléfono y comunidad; el correo NO se modifica. p_actualizado = false si no existe (404)
CREATE OR REPLACE PROCEDURE sp_actualizar_perfil(
    p_id_usuario           INTEGER,
    p_nombre               VARCHAR,
    p_apellido_paterno     VARCHAR,
    p_apellido_materno     VARCHAR,
    p_telefono             VARCHAR,
    p_comunidad_municipio  VARCHAR,
    INOUT p_actualizado    BOOLEAN DEFAULT NULL)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
    -- fecha_actualizacion la llena el trigger tg_usuario_actualizacion
    UPDATE usuario
    SET nombre              = trim(p_nombre),
        apellido_paterno    = trim(p_apellido_paterno),
        apellido_materno    = nullif(trim(p_apellido_materno), ''),
        telefono            = nullif(trim(p_telefono), ''),
        comunidad_municipio = nullif(trim(p_comunidad_municipio), '')
    WHERE id_usuario = p_id_usuario AND activo;

    p_actualizado := FOUND;
END;
$$;
--rollback DROP PROCEDURE IF EXISTS sp_actualizar_perfil(INTEGER, VARCHAR, VARCHAR, VARCHAR, VARCHAR, VARCHAR, BOOLEAN);

--changeset victor:018-03-sp-obtener-hash-contrasena splitStatements:false
--comment: HU-26 · Hash BCrypt actual del usuario, para que la API verifique la contraseña actual; NULL si no existe
CREATE OR REPLACE PROCEDURE sp_obtener_hash_contrasena(
    p_id_usuario             INTEGER,
    INOUT p_contrasena_hash  VARCHAR DEFAULT NULL)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
    SELECT contrasena_hash INTO p_contrasena_hash
    FROM usuario
    WHERE id_usuario = p_id_usuario AND activo;
END;
$$;
--rollback DROP PROCEDURE IF EXISTS sp_obtener_hash_contrasena(INTEGER, VARCHAR);

--changeset victor:018-04-sp-cambiar-contrasena splitStatements:false
--comment: HU-26 · Guarda el hash nuevo y cierra las demás sesiones abiertas (motivo «revocada»); la sesión actual (p_jti_actual) sigue abierta
CREATE OR REPLACE PROCEDURE sp_cambiar_contrasena(
    p_id_usuario           INTEGER,
    p_nuevo_hash           VARCHAR,
    p_jti_actual           VARCHAR,
    INOUT p_actualizado    BOOLEAN DEFAULT NULL)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
    UPDATE usuario
    SET contrasena_hash   = p_nuevo_hash,
        intentos_fallidos = 0,
        bloqueado_hasta   = NULL
    WHERE id_usuario = p_id_usuario AND activo;

    p_actualizado := FOUND;
    IF NOT p_actualizado THEN
        RETURN;                                                   -- la API responde 404
    END IF;

    -- Si alguien más conocía la contraseña anterior, pierde el acceso en sus dispositivos
    UPDATE sesion
    SET fecha_cierre = now(), motivo_cierre = 'revocada'
    WHERE id_usuario = p_id_usuario
      AND fecha_cierre IS NULL
      AND jti IS DISTINCT FROM p_jti_actual;
END;
$$;
--rollback DROP PROCEDURE IF EXISTS sp_cambiar_contrasena(INTEGER, VARCHAR, VARCHAR, BOOLEAN);
