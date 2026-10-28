--liquibase formatted sql

--changeset victor:012-01-sp-obtener-resumen-dashboard splitStatements:false
--comment: HU-12 · Totales del dashboard y pasos de la guía, solo con datos del usuario
CREATE OR REPLACE PROCEDURE sp_obtener_resumen_dashboard(
    p_id_usuario       INTEGER,
    p_zona_horaria     VARCHAR DEFAULT 'America/Mexico_City',
    INOUT p_resultado  REFCURSOR DEFAULT 'resultado')
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    -- Inicio del mes actual en la hora local del productor
    v_inicio_mes TIMESTAMPTZ := date_trunc('month', now() AT TIME ZONE p_zona_horaria) AT TIME ZONE p_zona_horaria;
BEGIN
    OPEN p_resultado FOR
        SELECT u.nombre,
               (SELECT count(*) FROM cultivo c
                 WHERE c.id_usuario = u.id_usuario AND c.estado = 'activo')::INTEGER        AS cultivos_activos,
               (SELECT count(*) FROM avance a
                 WHERE a.id_usuario = u.id_usuario AND a.fecha_actividad >= v_inicio_mes)::INTEGER AS avances_del_mes,
               EXISTS (SELECT 1 FROM parcela p WHERE p.id_usuario = u.id_usuario AND p.activo) AS tiene_parcela,
               EXISTS (SELECT 1 FROM cultivo c WHERE c.id_usuario = u.id_usuario)             AS tiene_cultivo,
               EXISTS (SELECT 1 FROM avance a WHERE a.id_usuario = u.id_usuario)              AS tiene_avance
        FROM usuario u
        WHERE u.id_usuario = p_id_usuario
          AND u.activo;
END;
$$;
--rollback DROP PROCEDURE IF EXISTS sp_obtener_resumen_dashboard(INTEGER, VARCHAR, REFCURSOR);

--changeset victor:012-02-sp-obtener-actividad-reciente splitStatements:false
--comment: HU-12 · Últimos avances del usuario (tipo, cultivo y fecha), del más reciente al más antiguo
CREATE OR REPLACE PROCEDURE sp_obtener_actividad_reciente(
    p_id_usuario       INTEGER,
    p_limite           INTEGER DEFAULT 5,
    INOUT p_resultado  REFCURSOR DEFAULT 'resultado')
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
    OPEN p_resultado FOR
        SELECT ta.nombre AS tipo,
               c.nombre  AS cultivo,
               a.fecha_actividad AS fecha
        FROM avance a
        JOIN cultivo c         ON c.id_cultivo = a.id_cultivo
        JOIN tipo_actividad ta ON ta.id_tipo_actividad = a.id_tipo_actividad
        WHERE a.id_usuario = p_id_usuario
        ORDER BY a.fecha_actividad DESC, a.id_avance DESC
        LIMIT least(greatest(p_limite, 1), 20);
END;
$$;
--rollback DROP PROCEDURE IF EXISTS sp_obtener_actividad_reciente(INTEGER, INTEGER, REFCURSOR);