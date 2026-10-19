--liquibase formatted sql

-- =====================================================================
--  AGRO · HU-30 · Migración 005: RESTRICCIÓN
--  Motivo (HU-26 · Mi perfil): "El teléfono debe tener 10 dígitos".
--  La restricción original aceptaba de 10 a 15 dígitos.
--  Precondición: no se aplica si algún teléfono existente no cumple.
-- =====================================================================

--changeset victor:005-01-telefono-10-digitos
--comment: HU-26 · El teléfono debe tener exactamente 10 dígitos
--preconditions onFail:HALT onError:HALT
--precondition-sql-check expectedResult:0 SELECT count(*) FROM usuario WHERE telefono !~ '^[0-9]{10}$'
ALTER TABLE usuario
    DROP CONSTRAINT ck_usuario_telefono,
    ADD CONSTRAINT ck_usuario_telefono CHECK (telefono ~ '^[0-9]{10}$');
--rollback ALTER TABLE usuario DROP CONSTRAINT ck_usuario_telefono, ADD CONSTRAINT ck_usuario_telefono CHECK (telefono ~ '^[0-9]{10,15}$');