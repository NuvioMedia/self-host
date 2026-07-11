BEGIN;

DROP TRIGGER IF EXISTS on_auth_user_created_addons ON auth.users;
CREATE TRIGGER on_auth_user_created_addons
AFTER INSERT ON auth.users
FOR EACH ROW
EXECUTE FUNCTION public.handle_new_user_default_addons();

INSERT INTO nuvio_migrations.schema_migrations (version)
VALUES ('00000000000001')
ON CONFLICT (version) DO NOTHING;

COMMIT;
