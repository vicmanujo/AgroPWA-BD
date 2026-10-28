# AgroPWA-BD

[![BD · Validar migraciones](https://github.com/vicmanujo/AgroPWA-BD/actions/workflows/migraciones.yml/badge.svg)](https://github.com/vicmanujo/AgroPWA-BD/actions/workflows/migraciones.yml)

Versionamiento de la base de datos **`agro_db`** (PostgreSQL) de **Agro**, la PWA para el registro y seguimiento de cultivos.
HU-30 · Versionamiento de la base de datos con migraciones · Sprint 3
HU-09, HU-10, HU-11 · Procedimientos almacenados de autenticación · Sprint 4
HU-12, HU-13 · Procedimientos del dashboard y de parcelas · Sprint 5
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
│       ├── 005_restriccion_telefono_10_digitos.sql
│       ├── 006_sp_registrar_usuario.sql
│       ├── 007_sp_inicio_sesion.sql
│       ├── 008_sp_sesion_activa.sql
│       ├── 009_sp_cerrar_sesion.sql
│       ├── 010_seguridad_solo_procedimientos.sql
│       ├── 011_sp_parcelas.sql
│       └── 012_sp_dashboard.sql
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
| 006 | Procedimiento | `sp_registrar_usuario`: crea el productor (correo repetido → `unique_violation`) | HU-09 | `DROP PROCEDURE` |
| 007 | Procedimientos | `sp_obtener_usuario_login` (cursor) · `sp_registrar_intento_acceso` (bloqueo de 15 min al 5.º fallo) · `sp_crear_sesion` | HU-10 | `DROP PROCEDURE` |
| 008 | Procedimientos | `sp_validar_sesion` (vencimiento y 20 min de inactividad) · `sp_renovar_sesion` (rota `jti` y refresh token) | HU-10 | `DROP PROCEDURE` |
| 009 | Procedimiento | `sp_cerrar_sesion` (`motivo_cierre = 'logout'`) | HU-11 | `DROP PROCEDURE` |
| 010 | **Seguridad** | `agro_app` solo puede ejecutar procedimientos (sin acceso directo a tablas); precondición: existen `agro_app` y `agro_admin` | HU-09 a HU-11 | Devuelve los permisos anteriores |
| 011 | Procedimientos | `sp_registrar_parcela` (si el `id_local` ya existe devuelve la existente; nombre único por usuario sin mayúsculas) · `sp_editar_parcela` (`false` si no es del usuario) · `sp_obtener_parcelas` (cursor, con número de cultivos) | HU-13 | `DROP PROCEDURE` |
| 012 | Procedimientos | `sp_obtener_resumen_dashboard` (totales y guía; «avances del mes» en hora de México) · `sp_obtener_actividad_reciente` (últimos N avances, máx. 20) | HU-12 | `DROP PROCEDURE` |

En total son **28 changesets**.

**Regla:** una migración ya aplicada **nunca se modifica** (Liquibase lo detecta por su checksum).
Cada cambio nuevo es un archivo nuevo al final de `db.changelog-master.yaml`.

## Procedimientos almacenados

La API **no consulta las tablas directamente**: todo pasa por procedimientos almacenados.

| Tipo | Cómo se escribe | Cómo lo llama la API |
|---|---|---|
| Escritura | `CREATE PROCEDURE sp_x(…, INOUT p_id INTEGER DEFAULT NULL)` | `CALL sp_x(@p1, …, NULL)` y lee el valor `INOUT` |
| Lectura | `INOUT p_resultado REFCURSOR DEFAULT 'resultado'` + `OPEN p_resultado FOR SELECT …` | En una transacción: `CALL sp_x(@p1, NULL)` y `FETCH ALL FROM resultado` |

- Todos usan `SECURITY DEFINER` y `SET search_path = public`: se ejecutan con los permisos del dueño
  y no se pueden engañar con otro esquema.
- Cada changeset de procedimiento usa `splitStatements:false`, porque el cuerpo `$$ … $$` lleva `;` internos.
- Los parámetros llegan tipados desde la API (`NpgsqlParameter`), así que no hay inyección SQL.

### Permisos (migración 010)

| Usuario | Puede |
|---|---|
| `agro_admin` | Todo (dueño de las tablas y procedimientos; solo para migraciones y mantenimiento) |
| `agro_app` (API) | **Solo `EXECUTE`** en los procedimientos de `public`. Sin `SELECT`, `INSERT`, `UPDATE` ni `DELETE` en tablas |
| `PUBLIC` | Nada: se le quitó el `EXECUTE` por defecto |

Los procedimientos que se creen después heredan esos permisos (`ALTER DEFAULT PRIVILEGES`).
En una base sin esos roles (desarrollo local) la 010-02 se marca como aplicada sin ejecutarse (`MARK_RAN`).

Para comprobarlo en Azure, conectado como `agro_admin`:

```sql
SELECT has_table_privilege('agro_app', 'usuario', 'SELECT');                -- false
SELECT has_function_privilege('agro_app', 'sp_cerrar_sesion(varchar, boolean)', 'EXECUTE');  -- true
```

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
liquibase status --verbose      # cambios pendientes (28 en una base vacía)
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
liquibase rollback v1.0-hu03    # regresa a la base de la HU-03 (revierte de la 003 a la 012)
liquibase update                # reaplica los cambios revertidos
```

> El *rollback* de la **010-02** necesita los roles `agro_app` y `agro_admin`. En una base local sin ellos,
> revertir hasta antes de la 010 falla: créalos antes (`CREATE ROLE agro_admin NOLOGIN; CREATE ROLE agro_app NOLOGIN;`)
> o revierte solo hasta la 010 (`rollback-count`).

**Demostración (Sprint 3):** se revirtió la 005 con `rollback-count 1` (la restricción volvió a `{10,15}` y se pudo
insertar un teléfono de 12 dígitos). Al reaplicar, la **precondición** detuvo la migración porque ese dato no cumplía
la nueva regla; tras corregirlo, `update` la reaplicó.

## Integración continua (GitHub Actions)

Workflow: [`.github/workflows/migraciones.yml`](.github/workflows/migraciones.yml)

| Evento | Qué hace |
|---|---|
| Push a `main`, `develop` o `Sprint*` y Pull Request hacia esas ramas | Levanta un PostgreSQL 16 vacío, crea los roles `agro_admin` y `agro_app`, y ejecuta `validate`, `status`, **`update-testing-rollback`** (aplica, revierte y reaplica todo) e `history` |
| Manual | Actions → *BD · Validar migraciones (Liquibase)* → *Run workflow* |

- La base de CI es temporal; sus credenciales (`agro_ci`) no son reales ni secretas.
- Los roles se crean `NOLOGIN` (sin contraseña): solo existen para que la 010 se aplique y se revierta
  igual que en Azure. Sin ellos el check fallaba: la 010-02 se saltaba (`MARK_RAN`), pero su *rollback*
  sí se ejecutaba y no encontraba los roles.
- La descarga del driver de PostgreSQL se reintenta hasta 3 veces por si falla la red.

## Flujo de ramas

```
SprintN_Victor ─► develop ─► main
```

Todo cambio llega por Pull Request; cada PR valida las migraciones automáticamente.

## Aplicar las migraciones en Azure

Después del merge a `main` y **antes** de desplegar el backend que las usa (si no, sus endpoints responden 500).
Requisitos: servidor `agropwa-db-2` iniciado y tu IP en el firewall (**Redes → Agregar dirección IP del cliente actual**).

La contraseña de `agro_admin` se pasa en una variable de entorno para que **no quede escrita en el comando ni en el
historial** de PowerShell:

```powershell
$env:LIQUIBASE_COMMAND_PASSWORD = [System.Net.NetworkCredential]::new("", (Read-Host "Contraseña de agro_admin" -AsSecureString)).Password
$azure = "jdbc:postgresql://agropwa-db-2.postgres.database.azure.com:5432/agro_db?sslmode=require"

liquibase --url=$azure --username=agro_admin status --verbose   # qué falta
liquibase --url=$azure --username=agro_admin update             # aplicar
liquibase --url=$azure --username=agro_admin history            # comprobar

Remove-Item Env:LIQUIBASE_COMMAND_PASSWORD
```

`status`, `update` y `history` son **comandos distintos** (no opciones de `status`).

| Sprint | Migraciones aplicadas en Azure |
|---|---|
| 3 | 001 a 005 |
| 4 | 006 a 010 |
| 5 | 011 y 012 |
