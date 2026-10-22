--liquibase formatted sql

--changeset victor:007-01-sp-obtener-usuario-login splitStatements:false
--comment: HU-10 · Consulta los datos necesarios para iniciar sesión (devuelve un cursor)
CREATE OR REPLACE PROCEDURE sp_obtener_usuario_login(
    p_correo           VARCHAR,
    INOUT p_resultado  REFCURSOR DEFAULT 'resultado')
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
    OPEN p_resultado FOR
        SELECT u.id_usuario, u.nombre, u.correo, u.contrasena_hash,
               r.nombre AS rol, u.bloqueado_hasta
        FROM usuario u
        JOIN rol r ON r.id_rol = u.id_rol
        WHERE lower(u.correo) = lower(trim(p_correo))
          AND u.activo;
END;
$$;
--rollback DROP PROCEDURE IF EXISTS sp_obtener_usuario_login(VARCHAR, REFCURSOR);

--changeset victor:007-02-sp-registrar-intento-acceso splitStatements:false
--comment: HU-10 · Registra cada intento de acceso y bloquea 15 minutos al 5.º fallo
CREATE OR REPLACE PROCEDURE sp_registrar_intento_acceso(
    p_correo          VARCHAR,
    p_id_usuario      INTEGER,
    p_exitoso         BOOLEAN,
    p_ip              VARCHAR,
    p_agente_usuario  VARCHAR)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
    INSERT INTO intento_acceso (correo, id_usuario, exitoso, ip, agente_usuario)
    VALUES (lower(trim(p_correo)), p_id_usuario, p_exitoso, p_ip, p_agente_usuario);

    IF p_id_usuario IS NULL THEN
        RETURN;   -- el correo no existe: solo queda el registro del intento
    END IF;

    IF p_exitoso THEN
        UPDATE usuario
        SET intentos_fallidos = 0, bloqueado_hasta = NULL, ultimo_acceso = now()
        WHERE id_usuario = p_id_usuario;
    ELSE
        UPDATE usuario
        SET intentos_fallidos = CASE WHEN intentos_fallidos + 1 >= 5 THEN 0 ELSE intentos_fallidos + 1 END,
            bloqueado_hasta   = CASE WHEN intentos_fallidos + 1 >= 5 THEN now() + INTERVAL '15 minutes'
                                     ELSE bloqueado_hasta END
        WHERE id_usuario = p_id_usuario;
    END IF;
END;
$$;
--rollback DROP PROCEDURE IF EXISTS sp_registrar_intento_acceso(VARCHAR, INTEGER, BOOLEAN, VARCHAR, VARCHAR);

--changeset victor:007-03-sp-crear-sesion splitStatements:false
--comment: HU-10 · Crea la sesión con el jti y el hash del refresh token; devuelve su id
CREATE OR REPLACE PROCEDURE sp_crear_sesion(
    p_id_usuario          INTEGER,
    p_jti                 VARCHAR,
    p_refresh_token_hash  VARCHAR,
    p_fecha_expiracion    TIMESTAMPTZ,
    p_ip                  VARCHAR,
    p_agente_usuario      VARCHAR,
    INOUT p_id_sesion     INTEGER DEFAULT NULL)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
    INSERT INTO sesion (id_usuario, jti, refresh_token_hash, fecha_expiracion, ip, agente_usuario)
    VALUES (p_id_usuario, p_jti, p_refresh_token_hash, p_fecha_expiracion, p_ip, p_agente_usuario)
    RETURNING id_sesion INTO p_id_sesion;
END;
$$;
--rollback DROP PROCEDURE IF EXISTS sp_crear_sesion(INTEGER, VARCHAR, VARCHAR, TIMESTAMPTZ, VARCHAR, VARCHAR, INTEGER);