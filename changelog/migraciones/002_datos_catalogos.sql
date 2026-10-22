--liquibase formatted sql

-- =====================================================================
--  AGRO · HU-30 · Migración 002: datos iniciales de los catálogos
--  Origen: HU-03 · 02_datos_semilla.sql
-- =====================================================================

--changeset victor:002-01-catalogos-iniciales
--comment: Datos iniciales de rol, tipo_cultivo y tipo_actividad
INSERT INTO rol (nombre, descripcion) VALUES
    ('productor', 'Campesino o productor que registra sus cultivos'),
    ('asesor',    'Asesor agrónomo (reservado; HU-24 y HU-25 canceladas)')
ON CONFLICT (nombre) DO NOTHING;

INSERT INTO tipo_cultivo (nombre) VALUES
    ('Maíz'), ('Frijol'), ('Calabaza'), ('Chile'), ('Hortaliza'), ('Otro')
ON CONFLICT (nombre) DO NOTHING;

INSERT INTO tipo_actividad (nombre) VALUES
    ('Riego'), ('Fertilización'), ('Avance'), ('Plaga o enfermedad'), ('Otra')
ON CONFLICT (nombre) DO NOTHING;
--rollback DELETE FROM tipo_actividad WHERE nombre IN ('Riego', 'Fertilización', 'Avance', 'Plaga o enfermedad', 'Otra');
--rollback DELETE FROM tipo_cultivo WHERE nombre IN ('Maíz', 'Frijol', 'Calabaza', 'Chile', 'Hortaliza', 'Otro');
--rollback DELETE FROM rol WHERE nombre IN ('productor', 'asesor');