--liquibase formatted sql

--changeset victor:009-01-sp-cerrar-sesion splitStatements:false
--comment: HU-11 · Cierra la sesión del token actual (logout)
CREATE OR REPLACE PROCEDURE sp_cerrar_sesion(
    p_jti            VARCHAR,
    INOUT p_cerrada  BOOLEAN DEFAULT NULL)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
    UPDATE sesion
       SET fecha_cierre = now(), motivo_cierre = 'logout'
     WHERE jti = p_jti
       AND fecha_cierre IS NULL;

    -- FOUND indica si el UPDATE modificó alguna fila
    p_cerrada := FOUND;
END;
$$;
--rollback DROP PROCEDURE IF EXISTS sp_cerrar_sesion(VARCHAR, BOOLEAN);