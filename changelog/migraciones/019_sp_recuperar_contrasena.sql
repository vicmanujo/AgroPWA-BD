--liquibase formatted sql

--changeset victor:019-01-ix-codigo-verificacion-hash
--comment: HU-27 · Búsqueda del código por su hash al restablecer la contraseña
CREATE INDEX ix_codigo_verificacion_hash ON codigo_verificacion (codigo_hash);
--rollback DROP INDEX IF EXISTS ix_codigo_verificacion_hash;

--changeset victor:019-02-sp-crear-codigo-recuperacion splitStatements:false
--comment: HU-27 · Si el correo es de un usuario activo, guarda el HASH de un token de un solo uso (30 min) e invalida los anteriores.
--p_enviar = true solo si hay que mandar el correo. Máximo 3 solicitudes por hora por usuario (las demás no se envían).
--La API responde lo mismo en todos los casos, para no revelar qué correos están registrados.
CREATE OR REPLACE PROCEDURE sp_crear_codigo_recuperacion(
    p_correo             VARCHAR,
    p_codigo_hash        VARCHAR,
    p_minutos            INTEGER DEFAULT 30,
    p_maximo_por_hora    INTEGER DEFAULT 3,
    INOUT p_enviar       BOOLEAN DEFAULT NULL,
    INOUT p_nombre       VARCHAR DEFAULT NULL)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    v_id_usuario INTEGER;
BEGIN
    p_enviar := FALSE;

    SELECT id_usuario, nombre INTO v_id_usuario, p_nombre
    FROM usuario
    WHERE correo = lower(trim(p_correo)) AND activo;

    IF NOT FOUND THEN
        p_nombre := NULL;
        RETURN;                                     -- correo no registrado: no se envía nada
    END IF;

    IF (SELECT count(*) FROM codigo_verificacion
        WHERE id_usuario = v_id_usuario AND tipo = 'recuperar_contrasena'
          AND fecha_creacion > now() - INTERVAL '1 hour') >= p_maximo_por_hora THEN
        RETURN;                                     -- demasiadas solicitudes: no se envía otro
    END IF;

    -- Solo el último enlace sirve: los anteriores sin usar se invalidan
    UPDATE codigo_verificacion
    SET fecha_uso = now()
    WHERE id_usuario = v_id_usuario AND tipo = 'recuperar_contrasena' AND fecha_uso IS NULL;

    INSERT INTO codigo_verificacion (id_usuario, tipo, codigo_hash, fecha_expiracion)
    VALUES (v_id_usuario, 'recuperar_contrasena', p_codigo_hash, now() + make_interval(mins => p_minutos));

    p_enviar := TRUE;
END;
$$;
--rollback DROP PROCEDURE IF EXISTS sp_crear_codigo_recuperacion(VARCHAR, VARCHAR, INTEGER, INTEGER, BOOLEAN, VARCHAR);

--changeset victor:019-03-sp-restablecer-contrasena splitStatements:false
--comment: HU-27 · Con un token vigente y sin usar: guarda el hash nuevo, marca el token como usado, quita el bloqueo
--y cierra TODAS las sesiones abiertas. p_restablecido = false si el token no existe, venció o ya se usó (400)
CREATE OR REPLACE PROCEDURE sp_restablecer_contrasena(
    p_codigo_hash          VARCHAR,
    p_nuevo_hash           VARCHAR,
    INOUT p_restablecido   BOOLEAN DEFAULT NULL)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    v_id_codigo  INTEGER;
    v_id_usuario INTEGER;
BEGIN
    -- FOR UPDATE: si llegan dos peticiones con el mismo token, solo una lo usa
    SELECT c.id_codigo, c.id_usuario INTO v_id_codigo, v_id_usuario
    FROM codigo_verificacion c
    JOIN usuario u ON u.id_usuario = c.id_usuario AND u.activo
    WHERE c.codigo_hash = p_codigo_hash
      AND c.tipo = 'recuperar_contrasena'
      AND c.fecha_uso IS NULL
      AND c.fecha_expiracion > now()
    FOR UPDATE OF c;

    IF NOT FOUND THEN
        p_restablecido := FALSE;
        RETURN;
    END IF;

    UPDATE codigo_verificacion SET fecha_uso = now() WHERE id_codigo = v_id_codigo;

    UPDATE usuario
    SET contrasena_hash = p_nuevo_hash, intentos_fallidos = 0, bloqueado_hasta = NULL
    WHERE id_usuario = v_id_usuario;

    UPDATE sesion
    SET fecha_cierre = now(), motivo_cierre = 'revocada'
    WHERE id_usuario = v_id_usuario AND fecha_cierre IS NULL;

    p_restablecido := TRUE;
END;
$$;
--rollback DROP PROCEDURE IF EXISTS sp_restablecer_contrasena(VARCHAR, VARCHAR, BOOLEAN);
