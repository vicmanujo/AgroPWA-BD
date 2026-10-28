--liquibase formatted sql

--changeset victor:011-01-sp-registrar-parcela splitStatements:false
--comment: HU-13 · Registra una parcela del usuario; si el id_local ya existe devuelve la existente (sincronización)
CREATE OR REPLACE PROCEDURE sp_registrar_parcela(
    p_id_usuario            INTEGER,
    p_id_local              UUID,
    p_nombre                VARCHAR,
    p_superficie_ha         NUMERIC,
    p_ubicacion_referencia  VARCHAR,
    INOUT p_id_parcela      INTEGER DEFAULT NULL,
    INOUT p_ya_existia      BOOLEAN DEFAULT NULL)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
    -- El dispositivo reenvió la misma parcela: no se duplica
    IF p_id_local IS NOT NULL THEN
        SELECT id_parcela INTO p_id_parcela
        FROM parcela
        WHERE id_usuario = p_id_usuario AND id_local = p_id_local;

        IF FOUND THEN
            p_ya_existia := TRUE;
            RETURN;
        END IF;
    END IF;

    -- Regla de negocio: nombre único por usuario (sin distinguir mayúsculas)
    IF EXISTS (SELECT 1 FROM parcela
               WHERE id_usuario = p_id_usuario AND lower(nombre) = lower(trim(p_nombre))) THEN
        RAISE EXCEPTION 'Ya tienes una parcela con ese nombre.' USING ERRCODE = 'unique_violation';
    END IF;

    INSERT INTO parcela (id_usuario, id_local, nombre, superficie_ha, ubicacion_referencia)
    VALUES (p_id_usuario, p_id_local, trim(p_nombre), p_superficie_ha,
            nullif(trim(p_ubicacion_referencia), ''))
    RETURNING id_parcela INTO p_id_parcela;

    p_ya_existia := FALSE;
END;
$$;
--rollback DROP PROCEDURE IF EXISTS sp_registrar_parcela(INTEGER, UUID, VARCHAR, NUMERIC, VARCHAR, INTEGER, BOOLEAN);

--changeset victor:011-02-sp-editar-parcela splitStatements:false
--comment: HU-13 · Edita una parcela activa del usuario; p_actualizada = false si no existe o no es suya
CREATE OR REPLACE PROCEDURE sp_editar_parcela(
    p_id_parcela            INTEGER,
    p_id_usuario            INTEGER,
    p_nombre                VARCHAR,
    p_superficie_ha         NUMERIC,
    p_ubicacion_referencia  VARCHAR,
    INOUT p_actualizada     BOOLEAN DEFAULT NULL)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM parcela
                   WHERE id_parcela = p_id_parcela AND id_usuario = p_id_usuario AND activo) THEN
        p_actualizada := FALSE;   -- la API responde 404
        RETURN;
    END IF;

    IF EXISTS (SELECT 1 FROM parcela
               WHERE id_usuario = p_id_usuario AND id_parcela <> p_id_parcela
                 AND lower(nombre) = lower(trim(p_nombre))) THEN
        RAISE EXCEPTION 'Ya tienes una parcela con ese nombre.' USING ERRCODE = 'unique_violation';
    END IF;

    UPDATE parcela
    SET nombre = trim(p_nombre),
        superficie_ha = p_superficie_ha,
        ubicacion_referencia = nullif(trim(p_ubicacion_referencia), '')
    WHERE id_parcela = p_id_parcela AND id_usuario = p_id_usuario;

    p_actualizada := TRUE;
END;
$$;
--rollback DROP PROCEDURE IF EXISTS sp_editar_parcela(INTEGER, INTEGER, VARCHAR, NUMERIC, VARCHAR, BOOLEAN);

--changeset victor:011-03-sp-obtener-parcelas splitStatements:false
--comment: HU-13 · Parcelas activas del usuario con su número de cultivos; con p_id_parcela devuelve solo esa
CREATE OR REPLACE PROCEDURE sp_obtener_parcelas(
    p_id_usuario       INTEGER,
    p_id_parcela       INTEGER DEFAULT NULL,
    INOUT p_resultado  REFCURSOR DEFAULT 'resultado')
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
    OPEN p_resultado FOR
        SELECT p.id_parcela, p.id_local, p.nombre, p.superficie_ha, p.ubicacion_referencia,
               count(c.id_cultivo)::INTEGER AS numero_cultivos
        FROM parcela p
        LEFT JOIN cultivo c ON c.id_parcela = p.id_parcela
        WHERE p.id_usuario = p_id_usuario
          AND p.activo
          AND (p_id_parcela IS NULL OR p.id_parcela = p_id_parcela)
        GROUP BY p.id_parcela
        ORDER BY p.nombre;
END;
$$;
--rollback DROP PROCEDURE IF EXISTS sp_obtener_parcelas(INTEGER, INTEGER, REFCURSOR);