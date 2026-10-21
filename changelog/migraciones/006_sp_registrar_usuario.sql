--liquibase formatted sql

--changeset victor:006-01-sp-registrar-usuario splitStatements:false
--comment: HU-09 · Procedimiento almacenado para registrar un productor
CREATE OR REPLACE PROCEDURE sp_registrar_usuario(
    p_nombre            VARCHAR,
    p_apellido_paterno  VARCHAR,
    p_apellido_materno  VARCHAR,
    p_correo            VARCHAR,
    p_telefono          VARCHAR,
    p_fecha_nacimiento  DATE,
    p_contrasena_hash   VARCHAR,
    INOUT p_id_usuario  INTEGER DEFAULT NULL)
LANGUAGE plpgsql
AS $$
DECLARE
    v_id_rol INTEGER;
BEGIN
    -- Regla de negocio: el correo es único (sin distinguir mayúsculas)
    IF EXISTS (SELECT 1 FROM usuario WHERE lower(correo) = lower(trim(p_correo))) THEN
        RAISE EXCEPTION 'Este correo ya está registrado.' USING ERRCODE = 'unique_violation';
    END IF;

    -- Todo usuario nuevo es productor
    SELECT id_rol INTO v_id_rol FROM rol WHERE nombre = 'productor';

    INSERT INTO usuario (id_rol, nombre, apellido_paterno, apellido_materno, correo, telefono,
                         fecha_nacimiento, contrasena_hash, fecha_aceptacion_terminos)
    VALUES (v_id_rol, trim(p_nombre), trim(p_apellido_paterno), nullif(trim(p_apellido_materno), ''),
            lower(trim(p_correo)), nullif(trim(p_telefono), ''), p_fecha_nacimiento,
            p_contrasena_hash, now())
    RETURNING id_usuario INTO p_id_usuario;
END;
$$;
--rollback DROP PROCEDURE IF EXISTS sp_registrar_usuario(VARCHAR, VARCHAR, VARCHAR, VARCHAR, VARCHAR, DATE, VARCHAR, INTEGER);