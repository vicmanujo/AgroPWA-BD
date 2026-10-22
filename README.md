# AgroPWA-BD

[![BD · Validar migraciones](https://github.com/vicmanujo/AgroPWA-BD/actions/workflows/migraciones.yml/badge.svg)](https://github.com/vicmanujo/AgroPWA-BD/actions/workflows/migraciones.yml)

Versionamiento de la base de datos **`agro_db`** (PostgreSQL) de **Agro**, la PWA para el registro y seguimiento de cultivos.
HU-30 · Versionamiento de la base de datos con migraciones · Sprint 3
Equipo: Victor Manuel Jose Jose · Jesus Alejandro Gutierrez Montufar (10 IDGS-G3, UTTT)

**Backend (API .NET):** [AlejandroGtz23/AgroPWA-Back](https://github.com/AlejandroGtz23/AgroPWA-Back) — genera sus entidades
con *scaffold* (database-first) a partir de la base que mantiene este repositorio.

## Herramienta: Liquibase Community

| Elemento | Valor |
|---|---|
| Liquibase | 5.0.4 (incluye su propio Java 21) |
| Driver | PostgreSQL JDBC (`liquibase lpm add postgresql --global`) |
| Motor | PostgreSQL 15 (desarrollo, Docker) · PostgreSQL 16 (Azure y CI) |
| Formato de migraciones | *Formatted SQL* (SQL puro con `--changeset` y `--rollback`) |
| Historial | Tablas `databasechangelog` y `databasechangeloglock` |

## Estructura

```
AgroPWA-BD/
├── .github/workflows/migraciones.yml     valida las migraciones en una base limpia (CI)
├── changelog/
│   ├── db.changelog-master.yaml          índice: orden en que se aplican las migraciones
│   └── migraciones/
│       ├── 001_esquema_base.sql
│       ├── 002_datos_catalogos.sql
│       ├── 003_crear_tabla_intento_acceso.sql
│       ├── 004_columnas_usuario_registro.sql
│       └── 005_restriccion_telefono_10_digitos.sql
├── liquibase.properties.example          plantilla de configuración (sin contraseña)
└── .gitignore                            ignora liquibase.properties y respaldos/
```

## Migraciones

| # | Tipo | Cambio | Historia | Rollback |
|---|---|---|---|---|
| 001 | Base | Esquema de la HU-03: 13 tablas, 34 CHECK, índices, 2 funciones y 5 triggers (9 changesets) | HU-03 | `DROP` en orden inverso |
| 002 | Datos | Catálogos `rol`, `tipo_cultivo` y `tipo_actividad` · etiqueta **`v1.0-hu03`** | HU-03 | `DELETE` de esos registros |
| 003 | **Creación de tabla** | `intento_acceso`: auditoría de inicios de sesión (bloqueo tras 5 fallos) | HU-10 | `DROP TABLE` |
| 004 | **Adición y modificación de columna** | `usuario.fecha_aceptacion_terminos` · `usuario.telefono` opcional | HU-09 | `DROP COLUMN` · `SET NOT NULL` |
| 005 | **Restricción** | `ck_usuario_telefono`: exactamente 10 dígitos, con **precondición** | HU-26 | Restaura `{10,15}` |

**Regla:** una migración ya aplicada **nunca se modifica** (Liquibase lo detecta por su checksum).
Cada cambio nuevo es un archivo nuevo al final de `db.changelog-master.yaml`.

## Instalación

1. Instala [Liquibase](https://github.com/liquibase/liquibase/releases) (instalador `windows-x64-installer`; agrega `liquibase` al PATH).
2. Instala el driver de PostgreSQL, en una terminal **como administrador**:
   ```bash
   liquibase lpm add postgresql --global
   ```
3. Verifica:
   ```bash
   liquibase --version
   ```

## Configuración

1. Copia `liquibase.properties.example` como `liquibase.properties` y escribe tus datos:

   | Propiedad | Ejemplo | Descripción |
   |---|---|---|
   | `changeLogFile` | `changelog/db.changelog-master.yaml` | Changelog maestro |
   | `url` | `jdbc:postgresql://localhost:5432/agro_db_dev` | Base de datos (formato JDBC) |
   | `username` | `mi_usuario` | Usuario de PostgreSQL |
   | `password` | — | Contraseña (**solo** en `liquibase.properties`, nunca en Git) |

2. Crea la base de desarrollo vacía (contenedor Docker `mi_postgres`):
   ```bash
   docker exec mi_postgres psql -U mi_usuario -d postgres -c "CREATE DATABASE agro_db_dev ENCODING 'UTF8' TEMPLATE template0;"
   ```

## Ejecución desde una base limpia

```bash
liquibase validate              # revisa el changelog
liquibase status --verbose      # cambios pendientes (14 en una base vacía)
liquibase update-sql            # (opcional) muestra el SQL sin ejecutarlo
liquibase update                # aplica todas las migraciones pendientes
liquibase history               # cambios aplicados: fecha, autor, id y etiqueta
```

Para usar otra base sin editar `liquibase.properties`: `--url=jdbc:postgresql://localhost:5432/OTRA_BASE`.

## Reversión (solo en desarrollo o pruebas)

> ⚠️ Nunca se prueban reversiones en Azure (producción). Antes de revertir, haz un respaldo.

```bash
# Respaldo
docker exec mi_postgres pg_dump -U mi_usuario -d agro_db_dev -F c -f /tmp/respaldo.dump
docker cp mi_postgres:/tmp/respaldo.dump respaldos/respaldo.dump

liquibase rollback-count-sql 1  # muestra el SQL de la reversión sin ejecutarlo
liquibase rollback-count 1      # revierte el último cambio
liquibase rollback v1.0-hu03    # regresa a la base de la HU-03 (revierte 003, 004 y 005)
liquibase update                # reaplica los cambios revertidos
```

**Demostración (Sprint 3):** se revirtió la 005 con `rollback-count 1` (la restricción volvió a `{10,15}` y se pudo
insertar un teléfono de 12 dígitos). Al reaplicar, la **precondición** detuvo la migración porque ese dato no cumplía
la nueva regla; tras corregirlo, `update` la reaplicó.

## Integración continua (GitHub Actions)

Workflow: [`.github/workflows/migraciones.yml`](.github/workflows/migraciones.yml)

| Evento | Qué hace |
|---|---|
| Push a `main`, `develop` o `Sprint*` y Pull Request hacia esas ramas | Levanta un PostgreSQL 16 vacío y ejecuta `validate`, `status`, **`update-testing-rollback`** (aplica, revierte y reaplica todo) e `history` |
| Manual | Actions → *BD · Validar migraciones (Liquibase)* → *Run workflow* |

La base de CI es temporal; sus credenciales (`agro_ci`) no son reales ni secretas.

## Flujo de ramas

```
Sprint3_Victor ─► develop ─► main
```

Todo cambio llega por Pull Request; cada PR valida las migraciones automáticamente.
