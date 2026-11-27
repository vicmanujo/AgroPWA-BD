--liquibase formatted sql

--changeset victor:020-01-sp-crear-codigo-verificacion-correo splitStatements:false
--comment: HU-32 · Guarda el HASH de un token para verificar el correo (24 h) e invalida los anteriores; máximo 3 por hora.
--p_enviar = false si el usuario no existe, ya verificó su correo o pidió demasiados (la API no lo informa: siempre 204)
CREATE OR REPLACE PROCEDURE sp_crear_codigo_verificacion_correo(
    p_id_usuario         INTEGER,
    p_codigo_hash        VARCHAR,
    p_horas              INTEGER DEFAULT 24,
    p_maximo_por_hora    INTEGER DEFAULT 3,
    INOUT p_enviar       BOOLEAN DEFAULT NULL,
    INOUT p_nombre       VARCHAR DEFAULT NULL,
    INOUT p_correo       VARCHAR DEFAULT NULL)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    v_verificado BOOLEAN;
BEGIN
    p_enviar := FALSE;

    SELECT nombre, correo, correo_verificado INTO p_nombre, p_correo, v_verificado
    FROM usuario
    WHERE id_usuario = p_id_usuario AND activo;

    IF NOT FOUND OR v_verificado THEN
        RETURN;                                     -- no existe o ya está verificado: nada que enviar
    END IF;

    IF (SELECT count(*) FROM codigo_verificacion
        WHERE id_usuario = p_id_usuario AND tipo = 'verificar_correo'
          AND fecha_creacion > now() - INTERVAL '1 hour') >= p_maximo_por_hora THEN
        RETURN;                                     -- demasiadas solicitudes
    END IF;

    -- Solo el último enlace sirve
    UPDATE codigo_verificacion
    SET fecha_uso = now()
    WHERE id_usuario = p_id_usuario AND tipo = 'verificar_correo' AND fecha_uso IS NULL;

    INSERT INTO codigo_verificacion (id_usuario, tipo, codigo_hash, fecha_expiracion)
    VALUES (p_id_usuario, 'verificar_correo', p_codigo_hash, now() + make_interval(hours => p_horas));

    p_enviar := TRUE;
END;
$$;
--rollback DROP PROCEDURE IF EXISTS sp_crear_codigo_verificacion_correo(INTEGER, VARCHAR, INTEGER, INTEGER, BOOLEAN, VARCHAR, VARCHAR);

--changeset victor:020-02-sp-verificar-correo splitStatements:false
--comment: HU-32 · Con un token vigente y sin usar marca el correo como verificado (un solo uso). p_verificado = false si no existe, venció o ya se usó (400)
CREATE OR REPLACE PROCEDURE sp_verificar_correo(
    p_codigo_hash         VARCHAR,
    INOUT p_verificado    BOOLEAN DEFAULT NULL)
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
      AND c.tipo = 'verificar_correo'
      AND c.fecha_uso IS NULL
      AND c.fecha_expiracion > now()
    FOR UPDATE OF c;

    IF NOT FOUND THEN
        p_verificado := FALSE;
        RETURN;
    END IF;

    UPDATE codigo_verificacion SET fecha_uso = now() WHERE id_codigo = v_id_codigo;
    UPDATE usuario SET correo_verificado = TRUE WHERE id_usuario = v_id_usuario;

    p_verificado := TRUE;
END;
$$;
--rollback DROP PROCEDURE IF EXISTS sp_verificar_correo(VARCHAR, BOOLEAN);

--changeset victor:020-03-sp-obtener-perfil-correo-verificado splitStatements:false rollbackSplitStatements:false
--comment: HU-32 · El perfil incluye correo_verificado (la app muestra el aviso «Verifica tu correo»)
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
               u.comunidad_municipio, r.nombre AS rol, u.fecha_registro, u.correo_verificado
        FROM usuario u
        JOIN rol r ON r.id_rol = u.id_rol
        WHERE u.id_usuario = p_id_usuario
          AND u.activo;
END;
$$;
--rollback CREATE OR REPLACE PROCEDURE sp_obtener_perfil(
--rollback     p_id_usuario       INTEGER,
--rollback     INOUT p_resultado  REFCURSOR DEFAULT 'resultado')
--rollback LANGUAGE plpgsql
--rollback SECURITY DEFINER
--rollback SET search_path = public
--rollback AS $$
--rollback BEGIN
--rollback     OPEN p_resultado FOR
--rollback         SELECT u.nombre, u.apellido_paterno, u.apellido_materno, u.correo, u.telefono,
--rollback                u.comunidad_municipio, r.nombre AS rol, u.fecha_registro
--rollback         FROM usuario u
--rollback         JOIN rol r ON r.id_rol = u.id_rol
--rollback         WHERE u.id_usuario = p_id_usuario
--rollback           AND u.activo;
--rollback END;
--rollback $$;
