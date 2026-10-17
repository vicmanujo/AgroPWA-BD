--liquibase formatted sql
-- =====================================================================
--  AGRO · PWA para el registro y seguimiento de cultivos
--  HU-03 · Diseño y creación de la base de datos (VERSIÓN OPTIMIZADA)
--  Gestor: PostgreSQL 13 o superior
--  Equipo: Victor Manuel Jose Jose · Jesus Alejandro Gutierrez Montufar
--
--  CAMBIOS Y MEJORAS APLICADAS:
--   * TIMESTAMP cambiado a TIMESTAMPTZ para soporte multi-zona horaria.
--     -> En el backend (.NET + Npgsql) usar siempre DateTime.UtcNow / DateTimeOffset.UtcNow.
--   * id_local compuesto por (id_usuario, id_local) para evitar colisiones globales.
--   * Coordenadas GPS (latitud, longitud) en parcelas y fotografías.
--   * Campo datos_json (JSONB) en cola_sincronizacion para auditar/reprocesar payloads.
--   * Adición de id_usuario en fotografia para reforzar aislamiento multitenant.
--   * La cola de sincronización valida que el dispositivo sea del mismo usuario.
--   * Sesiones: cierre automático por 20 minutos de inactividad (configurado en el backend).
--   * Índices de rendimiento para consultas frecuentes de la API.
--
--  Ejecutar conectado a agro_db (después de 00_crear_base_datos.sql).
--  Los catálogos iniciales están en 02_datos_semilla.sql.
-- =====================================================================


-- =====================================================================
-- 1. CATÁLOGOS
-- =====================================================================

--changeset victor:001-01-catalogos
--comment: Catálogos rol, tipo_cultivo y tipo_actividad
--rollback DROP TABLE tipo_actividad;
--rollback DROP TABLE tipo_cultivo;
--rollback DROP TABLE rol;

-- Tipos de usuario
CREATE TABLE rol (
    id_rol        INT GENERATED ALWAYS AS IDENTITY (START WITH 1 INCREMENT BY 1),
    nombre        VARCHAR(30)  NOT NULL,          -- productor, asesor
    descripcion   VARCHAR(150),
    CONSTRAINT pk_rol PRIMARY KEY (id_rol),
    CONSTRAINT uq_rol_nombre UNIQUE (nombre)
);

-- Tipos de cultivo (maíz, frijol…)
CREATE TABLE tipo_cultivo (
    id_tipo_cultivo INT GENERATED ALWAYS AS IDENTITY (START WITH 1 INCREMENT BY 1),
    nombre          VARCHAR(50) NOT NULL,
    activo          BOOLEAN     NOT NULL DEFAULT TRUE,   -- ocultar sin borrar
    CONSTRAINT pk_tipo_cultivo PRIMARY KEY (id_tipo_cultivo),
    CONSTRAINT uq_tipo_cultivo_nombre UNIQUE (nombre)
);

-- Tipos de actividad (riego, fertilización…)
CREATE TABLE tipo_actividad (
    id_tipo_actividad INT GENERATED ALWAYS AS IDENTITY (START WITH 1 INCREMENT BY 1),
    nombre            VARCHAR(50) NOT NULL,
    activo            BOOLEAN     NOT NULL DEFAULT TRUE,
    CONSTRAINT pk_tipo_actividad PRIMARY KEY (id_tipo_actividad),
    CONSTRAINT uq_tipo_actividad_nombre UNIQUE (nombre)
);

-- =====================================================================
-- 2. USUARIOS Y SEGURIDAD
-- =====================================================================

--changeset victor:001-02-usuarios-seguridad
--comment: usuario, dispositivo, sesion y codigo_verificacion con sus índices
--rollback DROP TABLE codigo_verificacion;
--rollback DROP TABLE sesion;
--rollback DROP TABLE dispositivo;
--rollback DROP TABLE usuario;

CREATE TABLE usuario (
    id_usuario          INT GENERATED ALWAYS AS IDENTITY (START WITH 1 INCREMENT BY 1),
    id_rol              INT          NOT NULL,
    nombre              VARCHAR(60)  NOT NULL,
    apellido_paterno    VARCHAR(60)  NOT NULL,
    apellido_materno    VARCHAR(60),                    -- opcional
    correo              VARCHAR(150) NOT NULL,          -- se usa para iniciar sesión
    telefono            VARCHAR(15)  NOT NULL,          -- 10 dígitos en México
    fecha_nacimiento    DATE         NOT NULL,
    contrasena_hash     VARCHAR(255) NOT NULL,          -- hash BCrypt, NUNCA texto plano
    comunidad_municipio VARCHAR(120),                   -- se completa en el perfil
    correo_verificado   BOOLEAN      NOT NULL DEFAULT FALSE,
    dos_pasos_activo    BOOLEAN      NOT NULL DEFAULT TRUE,  -- pedir código al iniciar sesión
    intentos_fallidos   INT          NOT NULL DEFAULT 0,     -- contraseñas incorrectas seguidas
    bloqueado_hasta     TIMESTAMPTZ,                        -- bloqueo temporal por intentos
    activo              BOOLEAN      NOT NULL DEFAULT TRUE,  -- baja lógica de la cuenta
    fecha_registro      TIMESTAMPTZ  NOT NULL DEFAULT CURRENT_TIMESTAMP,
    fecha_actualizacion TIMESTAMPTZ  NOT NULL DEFAULT CURRENT_TIMESTAMP,
    ultimo_acceso       TIMESTAMPTZ,
    CONSTRAINT pk_usuario PRIMARY KEY (id_usuario),
    CONSTRAINT fk_usuario_rol FOREIGN KEY (id_rol)
        REFERENCES rol (id_rol) ON DELETE RESTRICT,
    CONSTRAINT ck_usuario_nombre     CHECK (length(trim(nombre)) >= 2),
    CONSTRAINT ck_usuario_apellido   CHECK (length(trim(apellido_paterno)) >= 2),
    CONSTRAINT ck_usuario_correo     CHECK (correo ~* '^[^@\s]+@[^@\s]+\.[^@\s]+$'),
    CONSTRAINT ck_usuario_telefono   CHECK (telefono ~ '^[0-9]{10,15}$'),
    CONSTRAINT ck_usuario_nacimiento CHECK (fecha_nacimiento >= DATE '1900-01-01'),
    CONSTRAINT ck_usuario_hash       CHECK (length(contrasena_hash) >= 60),
    CONSTRAINT ck_usuario_intentos   CHECK (intentos_fallidos >= 0)
);

CREATE UNIQUE INDEX uq_usuario_correo ON usuario (lower(correo));
CREATE INDEX ix_usuario_rol ON usuario (id_rol);

-- Dispositivo móvil o navegador asignado a la PWA
CREATE TABLE dispositivo (
    id_dispositivo        INT GENERATED ALWAYS AS IDENTITY (START WITH 1 INCREMENT BY 1),
    id_usuario            INT          NOT NULL,
    identificador         VARCHAR(64)  NOT NULL,   -- UUID generado por el navegador/PWA
    nombre                VARCHAR(100) NOT NULL,   -- ej. "Chrome en Android"
    sincronizar_auto      BOOLEAN      NOT NULL DEFAULT TRUE,
    solo_wifi             BOOLEAN      NOT NULL DEFAULT FALSE,
    espacio_usado_mb      NUMERIC(8,2) NOT NULL DEFAULT 0,
    ultima_sincronizacion TIMESTAMPTZ,
    fecha_registro        TIMESTAMPTZ  NOT NULL DEFAULT CURRENT_TIMESTAMP,
    CONSTRAINT pk_dispositivo PRIMARY KEY (id_dispositivo),
    CONSTRAINT uq_dispositivo_usuario UNIQUE (id_usuario, identificador),
    CONSTRAINT uq_dispositivo_id_usuario UNIQUE (id_dispositivo, id_usuario),  -- Para FK compuesta de la cola
    CONSTRAINT fk_dispositivo_usuario FOREIGN KEY (id_usuario)
        REFERENCES usuario (id_usuario) ON DELETE CASCADE,
    CONSTRAINT ck_dispositivo_espacio CHECK (espacio_usado_mb >= 0)
);

CREATE INDEX ix_dispositivo_usuario ON dispositivo (id_usuario);

-- Sesiones activas y tokens.
-- Cierre por inactividad: si ultima_actividad tiene más de 20 minutos, la API
-- cierra la sesión con motivo_cierre = 'inactividad' (tiempo configurado en el backend).
CREATE TABLE sesion (
    id_sesion           INT GENERATED ALWAYS AS IDENTITY (START WITH 1 INCREMENT BY 1),
    id_usuario          INT          NOT NULL,
    id_dispositivo      INT,
    jti                 VARCHAR(64)  NOT NULL,          -- UUID del token de acceso JWT
    refresh_token_hash  VARCHAR(255) NOT NULL,          -- Hash del refresh token
    ip                  VARCHAR(45),                    -- IPv4 o IPv6
    agente_usuario      VARCHAR(300),                   -- User Agent
    fecha_inicio        TIMESTAMPTZ  NOT NULL DEFAULT CURRENT_TIMESTAMP,
    ultima_actividad    TIMESTAMPTZ  NOT NULL DEFAULT CURRENT_TIMESTAMP,
    fecha_expiracion    TIMESTAMPTZ  NOT NULL,
    fecha_cierre        TIMESTAMPTZ,                    -- NULL = sesión abierta
    motivo_cierre       VARCHAR(20),
    CONSTRAINT pk_sesion PRIMARY KEY (id_sesion),
    CONSTRAINT uq_sesion_jti UNIQUE (jti),
    CONSTRAINT uq_sesion_refresh UNIQUE (refresh_token_hash),
    CONSTRAINT fk_sesion_usuario FOREIGN KEY (id_usuario)
        REFERENCES usuario (id_usuario) ON DELETE CASCADE,
    CONSTRAINT fk_sesion_dispositivo FOREIGN KEY (id_dispositivo)
        REFERENCES dispositivo (id_dispositivo) ON DELETE SET NULL,
    CONSTRAINT ck_sesion_motivo CHECK (motivo_cierre IS NULL
        OR motivo_cierre IN ('logout', 'inactividad', 'expirada', 'revocada')),
    CONSTRAINT ck_sesion_cierre CHECK ((fecha_cierre IS NULL) = (motivo_cierre IS NULL)),
    CONSTRAINT ck_sesion_fechas CHECK (fecha_expiracion > fecha_inicio)
);

CREATE INDEX ix_sesion_abiertas ON sesion (id_usuario) WHERE fecha_cierre IS NULL;

-- Códigos OTP de verificación de 6 dígitos
CREATE TABLE codigo_verificacion (
    id_codigo        INT GENERATED ALWAYS AS IDENTITY (START WITH 1 INCREMENT BY 1),
    id_usuario       INT          NOT NULL,
    tipo             VARCHAR(25)  NOT NULL,
    codigo_hash      VARCHAR(255) NOT NULL,
    intentos         INT          NOT NULL DEFAULT 0,
    fecha_creacion   TIMESTAMPTZ  NOT NULL DEFAULT CURRENT_TIMESTAMP,
    fecha_expiracion TIMESTAMPTZ  NOT NULL,
    fecha_uso        TIMESTAMPTZ,
    CONSTRAINT pk_codigo_verificacion PRIMARY KEY (id_codigo),
    CONSTRAINT fk_codigo_usuario FOREIGN KEY (id_usuario)
        REFERENCES usuario (id_usuario) ON DELETE CASCADE,
    CONSTRAINT ck_codigo_tipo CHECK (tipo IN ('login_2fa', 'verificar_correo', 'recuperar_contrasena')),
    CONSTRAINT ck_codigo_intentos CHECK (intentos BETWEEN 0 AND 5),
    CONSTRAINT ck_codigo_fechas CHECK (fecha_expiracion > fecha_creacion)
);

CREATE INDEX ix_codigo_usuario_tipo ON codigo_verificacion (id_usuario, tipo);

-- =====================================================================
-- 3. PARCELAS Y CULTIVOS
-- =====================================================================

--changeset victor:001-03-parcelas-cultivos
--comment: parcela y cultivo (FK compuesta para aislar datos por usuario)
--rollback DROP TABLE cultivo;
--rollback DROP TABLE parcela;

CREATE TABLE parcela (
    id_parcela            INT GENERATED ALWAYS AS IDENTITY (START WITH 1 INCREMENT BY 1),
    id_usuario            INT          NOT NULL,
    id_local              UUID,                           -- UUID asignado offline en el móvil
    nombre                VARCHAR(80)  NOT NULL,
    superficie_ha         NUMERIC(8,2) NOT NULL,           -- hectáreas
    ubicacion_referencia  VARCHAR(150),
    latitud               NUMERIC(10,8),                  -- Coordenada GPS
    longitud              NUMERIC(11,8),                  -- Coordenada GPS
    activo                BOOLEAN      NOT NULL DEFAULT TRUE,
    fecha_creacion        TIMESTAMPTZ  NOT NULL DEFAULT CURRENT_TIMESTAMP,
    fecha_actualizacion   TIMESTAMPTZ  NOT NULL DEFAULT CURRENT_TIMESTAMP,
    CONSTRAINT pk_parcela PRIMARY KEY (id_parcela),
    CONSTRAINT uq_parcela_usuario_local UNIQUE (id_usuario, id_local),
    CONSTRAINT uq_parcela_nombre_usuario UNIQUE (id_usuario, nombre),
    CONSTRAINT uq_parcela_usuario UNIQUE (id_parcela, id_usuario),  -- Necesario para FK compuesta
    CONSTRAINT fk_parcela_usuario FOREIGN KEY (id_usuario)
        REFERENCES usuario (id_usuario) ON DELETE CASCADE,
    CONSTRAINT ck_parcela_superficie CHECK (superficie_ha > 0),
    CONSTRAINT ck_parcela_latitud CHECK (latitud IS NULL OR (latitud BETWEEN -90 AND 90)),
    CONSTRAINT ck_parcela_longitud CHECK (longitud IS NULL OR (longitud BETWEEN -180 AND 180))
);

CREATE TABLE cultivo (
    id_cultivo            INT GENERATED ALWAYS AS IDENTITY (START WITH 1 INCREMENT BY 1),
    id_usuario            INT          NOT NULL,
    id_parcela            INT          NOT NULL,
    id_tipo_cultivo       INT          NOT NULL,
    id_local              UUID,
    nombre                VARCHAR(80)  NOT NULL,          -- ej. "Maíz criollo"
    variedad              VARCHAR(80),
    fecha_siembra         DATE         NOT NULL,          -- Se mantiene DATE para días calendario
    fecha_cosecha         DATE,
    estado                VARCHAR(12)  NOT NULL DEFAULT 'activo',
    observaciones         VARCHAR(300),
    estado_sincronizacion VARCHAR(12)  NOT NULL DEFAULT 'sincronizado',
    fecha_creacion        TIMESTAMPTZ  NOT NULL DEFAULT CURRENT_TIMESTAMP,
    fecha_actualizacion   TIMESTAMPTZ  NOT NULL DEFAULT CURRENT_TIMESTAMP,
    CONSTRAINT pk_cultivo PRIMARY KEY (id_cultivo),
    CONSTRAINT uq_cultivo_usuario_local UNIQUE (id_usuario, id_local),
    CONSTRAINT uq_cultivo_usuario UNIQUE (id_cultivo, id_usuario),    -- Necesario para FK de avance/foto
    CONSTRAINT fk_cultivo_usuario FOREIGN KEY (id_usuario)
        REFERENCES usuario (id_usuario) ON DELETE CASCADE,
    CONSTRAINT fk_cultivo_parcela FOREIGN KEY (id_parcela, id_usuario)
        REFERENCES parcela (id_parcela, id_usuario) ON DELETE NO ACTION,
    CONSTRAINT fk_cultivo_tipo FOREIGN KEY (id_tipo_cultivo)
        REFERENCES tipo_cultivo (id_tipo_cultivo) ON DELETE RESTRICT,
    CONSTRAINT ck_cultivo_estado CHECK (estado IN ('activo', 'finalizado', 'perdido')),
    CONSTRAINT ck_cultivo_fechas CHECK (fecha_cosecha IS NULL OR fecha_cosecha >= fecha_siembra),
    CONSTRAINT ck_cultivo_sync   CHECK (estado_sincronizacion IN ('pendiente', 'sincronizado', 'error'))
);

CREATE INDEX ix_cultivo_usuario_estado ON cultivo (id_usuario, estado);
CREATE INDEX ix_cultivo_parcela ON cultivo (id_parcela);
CREATE INDEX ix_cultivo_tipo ON cultivo (id_tipo_cultivo);

-- =====================================================================
-- 4. AVANCES Y FOTOGRAFÍAS
-- =====================================================================

--changeset victor:001-04-avances-fotografias
--comment: avance y fotografia
--rollback DROP TABLE fotografia;
--rollback DROP TABLE avance;

CREATE TABLE avance (
    id_avance             INT GENERATED ALWAYS AS IDENTITY (START WITH 1 INCREMENT BY 1),
    id_cultivo            INT          NOT NULL,
    id_tipo_actividad     INT          NOT NULL,
    id_usuario            INT          NOT NULL,          -- quién lo registró (dueño del cultivo)
    id_local              UUID,
    fecha_actividad       TIMESTAMPTZ  NOT NULL,          -- fecha y hora de la labor realizada
    descripcion           VARCHAR(500) NOT NULL,
    duracion_min          INT,                            -- si es riego
    metodo_riego          VARCHAR(30),                    -- goteo, aspersión, etc.
    producto              VARCHAR(100),                   -- si es fertilización
    cantidad              NUMERIC(10,2),                  -- cantidad aplicada
    unidad                VARCHAR(20),                    -- kg, L, bultos, etc.
    estado_sincronizacion VARCHAR(12)  NOT NULL DEFAULT 'sincronizado',
    fecha_creacion        TIMESTAMPTZ  NOT NULL DEFAULT CURRENT_TIMESTAMP,
    fecha_actualizacion   TIMESTAMPTZ  NOT NULL DEFAULT CURRENT_TIMESTAMP,
    CONSTRAINT pk_avance PRIMARY KEY (id_avance),
    CONSTRAINT uq_avance_usuario_local UNIQUE (id_usuario, id_local),
    CONSTRAINT uq_avance_cultivo UNIQUE (id_avance, id_cultivo),       -- Para FK compuesta de foto
    -- El avance pertenece a un cultivo del MISMO usuario (también garantiza que el usuario existe)
    CONSTRAINT fk_avance_cultivo FOREIGN KEY (id_cultivo, id_usuario)
        REFERENCES cultivo (id_cultivo, id_usuario) ON DELETE CASCADE,
    CONSTRAINT fk_avance_tipo FOREIGN KEY (id_tipo_actividad)
        REFERENCES tipo_actividad (id_tipo_actividad) ON DELETE RESTRICT,
    CONSTRAINT ck_avance_duracion CHECK (duracion_min IS NULL OR duracion_min > 0),
    CONSTRAINT ck_avance_cantidad CHECK (cantidad IS NULL OR cantidad > 0),
    CONSTRAINT ck_avance_sync     CHECK (estado_sincronizacion IN ('pendiente', 'sincronizado', 'error'))
);

CREATE INDEX ix_avance_usuario ON avance (id_usuario);
CREATE INDEX ix_avance_cultivo_fecha ON avance (id_cultivo, fecha_actividad DESC);
CREATE INDEX ix_avance_tipo ON avance (id_tipo_actividad);

CREATE TABLE fotografia (
    id_fotografia         INT GENERATED ALWAYS AS IDENTITY (START WITH 1 INCREMENT BY 1),
    id_usuario            INT          NOT NULL,          -- Aislamiento multitenant
    id_cultivo            INT          NOT NULL,
    id_avance             INT,                            -- NULL = foto general del cultivo
    id_local              UUID,
    archivo_url           VARCHAR(500) NOT NULL,          -- Ruta en servidor/S3
    nombre_archivo        VARCHAR(150) NOT NULL,
    tamano_kb             INT          NOT NULL,
    es_portada            BOOLEAN      NOT NULL DEFAULT FALSE,
    latitud               NUMERIC(10,8),                  -- GPS donde se tomó la foto
    longitud              NUMERIC(11,8),                  -- GPS donde se tomó la foto
    fecha_captura         TIMESTAMPTZ  NOT NULL DEFAULT CURRENT_TIMESTAMP,
    estado_sincronizacion VARCHAR(12)  NOT NULL DEFAULT 'sincronizado',
    CONSTRAINT pk_fotografia PRIMARY KEY (id_fotografia),
    CONSTRAINT uq_fotografia_usuario_local UNIQUE (id_usuario, id_local),
    CONSTRAINT fk_fotografia_usuario FOREIGN KEY (id_usuario)
        REFERENCES usuario (id_usuario) ON DELETE CASCADE,
    CONSTRAINT fk_fotografia_cultivo FOREIGN KEY (id_cultivo, id_usuario)
        REFERENCES cultivo (id_cultivo, id_usuario) ON DELETE CASCADE,
    CONSTRAINT fk_fotografia_avance FOREIGN KEY (id_avance, id_cultivo)
        REFERENCES avance (id_avance, id_cultivo) ON DELETE CASCADE,
    CONSTRAINT ck_fotografia_tamano   CHECK (tamano_kb > 0 AND tamano_kb <= 5120),
    CONSTRAINT ck_fotografia_formato  CHECK (nombre_archivo ~* '\.(jpe?g|png)$'),
    CONSTRAINT ck_fotografia_sync     CHECK (estado_sincronizacion IN ('pendiente', 'sincronizado', 'error')),
    CONSTRAINT ck_fotografia_latitud  CHECK (latitud IS NULL OR (latitud BETWEEN -90 AND 90)),
    CONSTRAINT ck_fotografia_longitud CHECK (longitud IS NULL OR (longitud BETWEEN -180 AND 180))
);

CREATE INDEX ix_fotografia_usuario ON fotografia (id_usuario);
CREATE INDEX ix_fotografia_cultivo ON fotografia (id_cultivo);
CREATE INDEX ix_fotografia_avance ON fotografia (id_avance);
CREATE UNIQUE INDEX uq_fotografia_portada ON fotografia (id_cultivo) WHERE es_portada;

-- =====================================================================
-- 5. SINCRONIZACIÓN Y CONTACTO
-- =====================================================================

--changeset victor:001-05-sincronizacion-contacto
--comment: cola_sincronizacion y mensaje_contacto
--rollback DROP TABLE mensaje_contacto;
--rollback DROP TABLE cola_sincronizacion;

CREATE TABLE cola_sincronizacion (
    id_registro          INT GENERATED ALWAYS AS IDENTITY (START WITH 1 INCREMENT BY 1),
    id_usuario           INT          NOT NULL,
    id_dispositivo       INT          NOT NULL,
    entidad              VARCHAR(20)  NOT NULL,          -- tabla afectada
    id_local             UUID         NOT NULL,          -- id_local del registro afectado
    operacion            VARCHAR(10)  NOT NULL,          -- crear, editar, eliminar
    datos_json           JSONB        NOT NULL,          -- Payload enviado por la PWA
    estado               VARCHAR(12)  NOT NULL DEFAULT 'pendiente',
    intentos             INT          NOT NULL DEFAULT 0,
    mensaje_error        VARCHAR(300),
    fecha_creacion       TIMESTAMPTZ  NOT NULL DEFAULT CURRENT_TIMESTAMP,
    fecha_sincronizacion TIMESTAMPTZ,
    CONSTRAINT pk_cola_sincronizacion PRIMARY KEY (id_registro),
    CONSTRAINT fk_cola_usuario FOREIGN KEY (id_usuario)
        REFERENCES usuario (id_usuario) ON DELETE CASCADE,
    -- El dispositivo debe pertenecer al MISMO usuario
    CONSTRAINT fk_cola_dispositivo FOREIGN KEY (id_dispositivo, id_usuario)
        REFERENCES dispositivo (id_dispositivo, id_usuario) ON DELETE CASCADE,
    CONSTRAINT ck_cola_entidad   CHECK (entidad IN ('parcela', 'cultivo', 'avance', 'fotografia')),
    CONSTRAINT ck_cola_operacion CHECK (operacion IN ('crear', 'editar', 'eliminar')),
    CONSTRAINT ck_cola_estado    CHECK (estado IN ('pendiente', 'error', 'sincronizado')),
    CONSTRAINT ck_cola_intentos  CHECK (intentos >= 0),
    CONSTRAINT ck_cola_datos     CHECK (jsonb_typeof(datos_json) = 'object')
);

CREATE INDEX ix_cola_usuario_estado ON cola_sincronizacion (id_usuario, estado);
CREATE INDEX ix_cola_dispositivo_estado ON cola_sincronizacion (id_dispositivo, estado);

CREATE TABLE mensaje_contacto (
    id_mensaje   INT GENERATED ALWAYS AS IDENTITY (START WITH 1 INCREMENT BY 1),
    nombre       VARCHAR(120)  NOT NULL,
    correo       VARCHAR(150)  NOT NULL,
    asunto       VARCHAR(150),
    mensaje      VARCHAR(1000) NOT NULL,
    atendido     BOOLEAN       NOT NULL DEFAULT FALSE,
    fecha_envio  TIMESTAMPTZ   NOT NULL DEFAULT CURRENT_TIMESTAMP,
    CONSTRAINT pk_mensaje_contacto PRIMARY KEY (id_mensaje),
    CONSTRAINT ck_mensaje_correo CHECK (correo ~* '^[^@\s]+@[^@\s]+\.[^@\s]+$')
);

-- =====================================================================
-- 6. TRIGGERS Y FUNCIONES
-- =====================================================================

-- Actualización automática de la columna fecha_actualizacion

--changeset victor:001-06-fn-fecha-actualizacion splitStatements:false
--comment: Función que actualiza fecha_actualizacion en cada UPDATE
--rollback DROP FUNCTION fn_fecha_actualizacion();

CREATE FUNCTION fn_fecha_actualizacion() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
    NEW.fecha_actualizacion := CURRENT_TIMESTAMP;
    RETURN NEW;
END;
$$;

--changeset victor:001-07-tg-fecha-actualizacion
--comment: Triggers de fecha_actualizacion en usuario, parcela, cultivo y avance
--rollback DROP TRIGGER tg_avance_actualizacion ON avance;
--rollback DROP TRIGGER tg_cultivo_actualizacion ON cultivo;
--rollback DROP TRIGGER tg_parcela_actualizacion ON parcela;
--rollback DROP TRIGGER tg_usuario_actualizacion ON usuario;

CREATE TRIGGER tg_usuario_actualizacion BEFORE UPDATE ON usuario
    FOR EACH ROW EXECUTE FUNCTION fn_fecha_actualizacion();

CREATE TRIGGER tg_parcela_actualizacion BEFORE UPDATE ON parcela
    FOR EACH ROW EXECUTE FUNCTION fn_fecha_actualizacion();

CREATE TRIGGER tg_cultivo_actualizacion BEFORE UPDATE ON cultivo
    FOR EACH ROW EXECUTE FUNCTION fn_fecha_actualizacion();

CREATE TRIGGER tg_avance_actualizacion BEFORE UPDATE ON avance
    FOR EACH ROW EXECUTE FUNCTION fn_fecha_actualizacion();

-- Restricción a máximo 5 fotografías por avance

--changeset victor:001-08-fn-max-fotos-avance splitStatements:false
--comment: Función que limita a 5 las fotografías por avance
--rollback DROP FUNCTION fn_max_fotos_avance();

CREATE FUNCTION fn_max_fotos_avance() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
    IF NEW.id_avance IS NOT NULL AND (
        SELECT count(*) FROM fotografia
        WHERE id_avance = NEW.id_avance
          AND id_fotografia IS DISTINCT FROM NEW.id_fotografia
    ) >= 5 THEN
        RAISE EXCEPTION 'Un avance admite como máximo 5 fotografías'
            USING ERRCODE = 'check_violation';
    END IF;
    RETURN NEW;
END;
$$;

--changeset victor:001-09-tg-max-fotos-avance
--comment: Trigger que aplica el límite de fotografías
--rollback DROP TRIGGER tg_fotografia_max_avance ON fotografia;

CREATE TRIGGER tg_fotografia_max_avance BEFORE INSERT OR UPDATE OF id_avance ON fotografia
    FOR EACH ROW EXECUTE FUNCTION fn_max_fotos_avance();

