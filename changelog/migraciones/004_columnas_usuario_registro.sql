--liquibase formatted sql

-- =====================================================================
--  AGRO · HU-30 · Migración 004: ADICIÓN Y MODIFICACIÓN DE COLUMNA
--  Motivo (HU-09 · Registro de usuario):
--   * "Es obligatorio aceptar los términos y el aviso de privacidad":
--     se guarda la fecha de aceptación como evidencia.
--   * "teléfono (opcional)": la columna telefono deja de ser NOT NULL.
-- =====================================================================

--changeset victor:004-01-agregar-fecha-aceptacion-terminos
--comment: HU-09 · Fecha en que el usuario aceptó los términos y el aviso de privacidad
ALTER TABLE usuario
    ADD COLUMN fecha_aceptacion_terminos TIMESTAMPTZ;

COMMENT ON COLUMN usuario.fecha_aceptacion_terminos IS
    'Fecha de aceptación de los términos y el aviso de privacidad (HU-09). NULL en usuarios anteriores a la HU-09';
--rollback ALTER TABLE usuario DROP COLUMN fecha_aceptacion_terminos;

--changeset victor:004-02-telefono-opcional
--comment: HU-09 · El teléfono es opcional en el registro
ALTER TABLE usuario
    ALTER COLUMN telefono DROP NOT NULL;
--rollback ALTER TABLE usuario ALTER COLUMN telefono SET NOT NULL;