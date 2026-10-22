--liquibase formatted sql

-- =====================================================================
--  AGRO · HU-30 · Migración 003: CREACIÓN DE TABLA
--  Tabla intento_acceso: auditoría de los intentos de inicio de sesión.
--  Motivo (HU-10): "Después de 5 intentos fallidos se bloquea el acceso
--  durante 15 minutos". Registra también los correos no registrados.
-- =====================================================================

--changeset victor:003-01-crear-intento-acceso
--comment: HU-10 · Tabla de auditoría de intentos de inicio de sesión
CREATE TABLE intento_acceso (
    id_intento      INT GENERATED ALWAYS AS IDENTITY (START WITH 1 INCREMENT BY 1),
    correo          VARCHAR(150) NOT NULL,          -- correo escrito (exista o no)
    id_usuario      INT,                            -- NULL si el correo no está registrado
    exitoso         BOOLEAN      NOT NULL,
    ip              VARCHAR(45),                    -- IPv4 o IPv6
    agente_usuario  VARCHAR(300),                   -- User Agent
    fecha_intento   TIMESTAMPTZ  NOT NULL DEFAULT CURRENT_TIMESTAMP,
    CONSTRAINT pk_intento_acceso PRIMARY KEY (id_intento),
    CONSTRAINT fk_intento_usuario FOREIGN KEY (id_usuario)
        REFERENCES usuario (id_usuario) ON DELETE SET NULL,
    CONSTRAINT ck_intento_correo CHECK (length(trim(correo)) > 0)
);

CREATE INDEX ix_intento_correo_fecha ON intento_acceso (lower(correo), fecha_intento DESC);
CREATE INDEX ix_intento_usuario ON intento_acceso (id_usuario);
--rollback DROP TABLE intento_acceso;