--liquibase formatted sql

--changeset victor:008-01-sp-validar-sesion splitStatements:false
--comment: HU-10 · Valida en cada petición que la sesión siga abierta; la cierra por vencimiento o 20 min de inactividad
CREATE OR REPLACE PROCEDURE sp_validar_sesion(
    p_jti                  VARCHAR,
    p_minutos_inactividad  INTEGER,
    INOUT p_valida         BOOLEAN DEFAULT NULL)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    v_id_sesion         INTEGER;
    v_fecha_inicio      TIMESTAMPTZ;
    v_ultima_actividad  TIMESTAMPTZ;
    v_fecha_expiracion  TIMESTAMPTZ;
    v_fecha_cierre      TIMESTAMPTZ;
BEGIN
    p_valida := false;

    -- FOR UPDATE: bloquea la fila mientras se decide, por si llegan dos peticiones al mismo tiempo
    SELECT id_sesion, fecha_inicio, ultima_actividad, fecha_expiracion, fecha_cierre
      INTO v_id_sesion, v_fecha_inicio, v_ultima_actividad, v_fecha_expiracion, v_fecha_cierre
      FROM sesion
     WHERE jti = p_jti
       FOR UPDATE;

    -- No existe, o ya se cerró (logout, inactividad, expirada o revocada)
    IF NOT FOUND OR v_fecha_cierre IS NOT NULL THEN
        RETURN;
    END IF;

    -- Venció su tiempo de vida (12 horas, o 7 días con «Recordarme»)
    IF v_fecha_expiracion <= now() THEN
        UPDATE sesion SET fecha_cierre = now(), motivo_cierre = 'expirada'
         WHERE id_sesion = v_id_sesion;
        RETURN;
    END IF;

    -- Inactividad: solo para sesiones normales (las de «Recordarme» duran más de 1 día)
    IF v_fecha_expiracion - v_fecha_inicio <= INTERVAL '1 day'
       AND v_ultima_actividad < now() - make_interval(mins => p_minutos_inactividad) THEN
        UPDATE sesion SET fecha_cierre = now(), motivo_cierre = 'inactividad'
         WHERE id_sesion = v_id_sesion;
        RETURN;
    END IF;

    -- Sesión válida: se registra la actividad
    UPDATE sesion SET ultima_actividad = now() WHERE id_sesion = v_id_sesion;
    p_valida := true;
END;
$$;
--rollback DROP PROCEDURE IF EXISTS sp_validar_sesion(VARCHAR, INTEGER, BOOLEAN);

--changeset victor:008-02-sp-renovar-sesion splitStatements:false
--comment: HU-10 · Renueva la sesión con el refresh token: valida, rota jti y refresh token, y devuelve el usuario
CREATE OR REPLACE PROCEDURE sp_renovar_sesion(
    p_refresh_token_hash        VARCHAR,
    p_nuevo_jti                 VARCHAR,
    p_nuevo_refresh_token_hash  VARCHAR,
    p_minutos_inactividad       INTEGER,
    INOUT p_resultado           REFCURSOR DEFAULT 'resultado')
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    v_id_sesion  INTEGER;
    v_jti        VARCHAR;
    v_valida     BOOLEAN;
BEGIN
    SELECT id_sesion, jti
      INTO v_id_sesion, v_jti
      FROM sesion
     WHERE refresh_token_hash = p_refresh_token_hash
       FOR UPDATE;

    IF FOUND THEN
        -- Mismas reglas que en cada petición (abierta, no vencida, sin inactividad)
        CALL sp_validar_sesion(v_jti, p_minutos_inactividad, v_valida);

        IF v_valida THEN
            -- Rotación: el refresh token anterior deja de servir
            UPDATE sesion
               SET jti = p_nuevo_jti, refresh_token_hash = p_nuevo_refresh_token_hash
             WHERE id_sesion = v_id_sesion;
        ELSE
            v_id_sesion := NULL;
        END IF;
    END IF;

    -- Si no se renovó, el cursor sale vacío (el backend responde 401)
    OPEN p_resultado FOR
        SELECT u.id_usuario, u.nombre, u.correo, r.nombre AS rol
          FROM sesion s
          JOIN usuario u ON u.id_usuario = s.id_usuario
          JOIN rol r     ON r.id_rol = u.id_rol
         WHERE s.id_sesion = v_id_sesion
           AND u.activo;
END;
$$;
--rollback DROP PROCEDURE IF EXISTS sp_renovar_sesion(VARCHAR, VARCHAR, VARCHAR, INTEGER, REFCURSOR);