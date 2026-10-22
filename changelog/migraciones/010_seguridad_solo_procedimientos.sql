--liquibase formatted sql

--changeset victor:010-01-sp-registrar-usuario-definer
--comment: Seguridad · sp_registrar_usuario (006) también con SECURITY DEFINER y search_path fijo
ALTER PROCEDURE sp_registrar_usuario(VARCHAR, VARCHAR, VARCHAR, VARCHAR, VARCHAR, DATE, VARCHAR, INTEGER) SECURITY DEFINER;
ALTER PROCEDURE sp_registrar_usuario(VARCHAR, VARCHAR, VARCHAR, VARCHAR, VARCHAR, DATE, VARCHAR, INTEGER) SET search_path = public;
--rollback ALTER PROCEDURE sp_registrar_usuario(VARCHAR, VARCHAR, VARCHAR, VARCHAR, VARCHAR, DATE, VARCHAR, INTEGER) RESET search_path;
--rollback ALTER PROCEDURE sp_registrar_usuario(VARCHAR, VARCHAR, VARCHAR, VARCHAR, VARCHAR, DATE, VARCHAR, INTEGER) SECURITY INVOKER;

--changeset victor:010-02-permisos-solo-procedimientos
--preconditions onFail:MARK_RAN
--precondition-sql-check expectedResult:2 SELECT count(*) FROM pg_roles WHERE rolname IN ('agro_app', 'agro_admin')
--comment: Seguridad · agro_app (usuario de la API) solo ejecuta procedimientos; sin acceso directo a las tablas
REVOKE SELECT, INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA public FROM agro_app;
REVOKE USAGE, SELECT ON ALL SEQUENCES IN SCHEMA public FROM agro_app;
ALTER DEFAULT PRIVILEGES FOR ROLE agro_admin IN SCHEMA public REVOKE SELECT, INSERT, UPDATE, DELETE ON TABLES FROM agro_app;
ALTER DEFAULT PRIVILEGES FOR ROLE agro_admin IN SCHEMA public REVOKE USAGE, SELECT ON SEQUENCES FROM agro_app;
REVOKE EXECUTE ON ALL PROCEDURES IN SCHEMA public FROM PUBLIC;
GRANT EXECUTE ON ALL PROCEDURES IN SCHEMA public TO agro_app;
ALTER DEFAULT PRIVILEGES FOR ROLE agro_admin REVOKE EXECUTE ON ROUTINES FROM PUBLIC;
ALTER DEFAULT PRIVILEGES FOR ROLE agro_admin IN SCHEMA public GRANT EXECUTE ON ROUTINES TO agro_app;
--rollback GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA public TO agro_app;
--rollback GRANT USAGE, SELECT ON ALL SEQUENCES IN SCHEMA public TO agro_app;
--rollback ALTER DEFAULT PRIVILEGES FOR ROLE agro_admin IN SCHEMA public GRANT SELECT, INSERT, UPDATE, DELETE ON TABLES TO agro_app;
--rollback ALTER DEFAULT PRIVILEGES FOR ROLE agro_admin IN SCHEMA public GRANT USAGE, SELECT ON SEQUENCES TO agro_app;
--rollback GRANT EXECUTE ON ALL PROCEDURES IN SCHEMA public TO PUBLIC;
--rollback ALTER DEFAULT PRIVILEGES FOR ROLE agro_admin GRANT EXECUTE ON ROUTINES TO PUBLIC;