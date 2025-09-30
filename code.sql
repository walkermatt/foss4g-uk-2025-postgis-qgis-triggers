SELECT * FROM layer_styles;

UPDATE public.layer_styles SET f_table_name = 'place' WHERE f_table_schema = 'uk' AND f_table_name = 'venue';

ALTER TABLE public.layer_styles ADD COLUMN IF NOT EXISTS table_oid oid;

UPDATE public.layer_styles SET table_oid =
    to_regclass(quote_ident(f_table_schema) || '.' || quote_ident(f_table_name))::oid;

SELECT table_oid, * FROM public.layer_styles;

DROP FUNCTION IF EXISTS public.layer_styles_table_oid() CASCADE;
CREATE FUNCTION public.layer_styles_table_oid()
    RETURNS trigger
    LANGUAGE plpgsql
AS $BODY$
BEGIN
  NEW.table_oid = (to_regclass(quote_ident(NEW.f_table_schema) || '.' || quote_ident(NEW.f_table_name))::oid);
  RETURN NEW;
END;
$BODY$;

DROP TRIGGER IF EXISTS layer_styles_table_oid ON public.layer_styles;
CREATE TRIGGER layer_styles_table_oid
    BEFORE INSERT OR UPDATE
    ON public.layer_styles
    FOR EACH ROW EXECUTE PROCEDURE public.layer_styles_table_oid();

SELECT table_oid, * FROM public.layer_styles;

CREATE OR REPLACE FUNCTION on_alter_table()
RETURNS event_trigger AS $$
DECLARE
    ddl_cmd record;
    schema_name text;
    table_name text;
BEGIN
    FOR ddl_cmd IN
        SELECT * FROM pg_event_trigger_ddl_commands()
    LOOP
        IF ddl_cmd.command_tag = 'ALTER TABLE' AND ddl_cmd.object_type = 'table' THEN
            table_name = (parse_ident(ddl_cmd.object_identity))[2];
            UPDATE public.layer_styles SET f_table_schema =
                ddl_cmd.schema_name, f_table_name = table_name WHERE table_oid = ddl_cmd.objid;
        ELSIF ddl_cmd.command_tag = 'ALTER SCHEMA'  AND ddl_cmd.object_type = 'schema' THEN
            SELECT nspname INTO schema_name FROM pg_namespace WHERE oid = ddl_cmd.objid;
            UPDATE public.layer_styles SET f_table_schema = schema_name
                WHERE
                    table_oid IN (SELECT oid FROM pg_class WHERE pg_class.relnamespace = ddl_cmd.objid)
                    AND f_table_schema <> schema_name;
        END IF;
    END LOOP;
END;
$$ LANGUAGE plpgsql;

DROP EVENT TRIGGER IF EXISTS trg_alter_table;
CREATE EVENT TRIGGER trg_alter_table
    ON ddl_command_end
    WHEN TAG IN ('ALTER TABLE', 'ALTER SCHEMA')
    EXECUTE FUNCTION on_alter_table();

SELECT table_oid, * FROM public.layer_styles;

-- Equivalent of geometry_columns
SELECT * FROM raster_columns;

-- Overview raster tables
SELECT * FROM raster_overviews;

DROP FUNCTION IF EXISTS public._overview_constraint_oid(r_table_oid oid) CASCADE;
CREATE OR REPLACE FUNCTION public._overview_constraint_oid(r_table_oid oid)
RETURNS bool
LANGUAGE plpgsql
AS $$
BEGIN
  RETURN true;
END;
$$;
COMMENT ON FUNCTION public._overview_constraint_oid(r_table_oid oid)
  IS 'Function used to track the oid of the main raster that an overview raster is associated with via a CHECK CONSTRAINT.';

CREATE OR REPLACE FUNCTION public.add_rast_oid_constraints()
RETURNS void
LANGUAGE plpgsql
AS $$
DECLARE
  r record;
  rast_oid oid;
  sql_text text;
BEGIN
  -- Query for existing enforce_overview_rast_oid constraints, parse the oid of
  -- the main table and join with raster_overviews; add the enforce_overview_rast_oid
  -- to overviews that need it
  FOR r IN
    WITH
      -- Lookup existing rast_oid if it exists
      rast_oid AS
      (SELECT nsp.nspname o_table_schema,
              rel.relname o_table_name,
              substring(pg_get_expr(con.conbin, con.conrelid)
                        FROM '_overview_constraint_oid\(\((\d+)\)::oid\)')::oid AS rast_oid
      FROM pg_catalog.pg_constraint con
      INNER JOIN pg_catalog.pg_class rel ON rel.oid = con.conrelid
      INNER JOIN pg_catalog.pg_namespace nsp ON nsp.oid = connamespace
      WHERE conname = 'enforce_overview_rast_oid')
    -- Join raster_overviews with current rast_oid if it exists
    SELECT raster_overviews.*,
          rast_oid.rast_oid
    FROM public.raster_overviews
    LEFT JOIN rast_oid ON raster_overviews.o_table_schema = rast_oid.o_table_schema
    AND raster_overviews.o_table_name = rast_oid.o_table_name
  LOOP
      BEGIN
        rast_oid = regclass(quote_ident(r.r_table_schema) || '.' || quote_ident(r.r_table_name))::oid;
        EXCEPTION WHEN SQLSTATE '42704' OR SQLSTATE '3F000' THEN -- 42704 undefined_object (table doesn't exist), 3F000 invalid_schema_name (schema doesn't exist)
          RAISE WARNING 'SQLSTATE: %; ERROR: %; Unable to add CONSTRAINT enforce_overview_rast_oid.', SQLSTATE, SQLERRM;
          CONTINUE;
      END;
      -- Only update the enforce_overview_rast_oid constraint if needed
      IF rast_oid IS NOT NULL AND rast_oid IS DISTINCT FROM r.rast_oid THEN
        RAISE NOTICE 'rast_oid: %, r.rast_oid: %', rast_oid, r.rast_oid;
        sql_text = format('ALTER TABLE %I.%I DROP CONSTRAINT IF EXISTS enforce_overview_rast_oid;', r.o_table_schema, r.o_table_name);
        RAISE NOTICE '%', sql_text;
        EXECUTE sql_text;
        sql_text = format('ALTER TABLE %I.%I ADD CONSTRAINT enforce_overview_rast_oid CHECK (public._overview_constraint_oid(%s::oid)) NOT VALID;', r.o_table_schema, r.o_table_name, rast_oid);
        RAISE NOTICE '%', sql_text;
        EXECUTE sql_text;
      END IF;
  END LOOP;
END;
$$;
COMMENT ON FUNCTION public.add_rast_oid_constraints()
  IS 'Add constraint enforce_overview_rast_oid to all overview rasters to support updating enforce_overview_rast constraint with the current "schema"."table" of the main raster.';

-- Add constraint enforce_overview_rast_oid to all overview rasters before
-- ALTER TABLE
CREATE OR REPLACE FUNCTION raster_alter_start()
RETURNS event_trigger
LANGUAGE plpgsql
AS $$
BEGIN
    -- Avoid recursive calls to this trigger
    IF current_setting('tmp.executing__raster_alter_start', true) = 'true' OR
       current_setting('tmp.executing__raster_alter_end', true) = 'true' THEN
        RETURN;
    END IF;
    PERFORM set_config('tmp.executing__raster_alter_start', 'true', true);
    PERFORM public.add_rast_oid_constraints();
    PERFORM set_config('tmp.executing__raster_alter_start', 'false', true);
END;
$$;

DROP EVENT TRIGGER IF EXISTS trg_raster_alter_start;
CREATE EVENT TRIGGER trg_raster_alter_start ON ddl_command_start
  WHEN tag IN ('ALTER TABLE', 'ALTER SCHEMA')
  EXECUTE PROCEDURE raster_alter_start();

CREATE OR REPLACE FUNCTION public.update_raster_overview_constraints()
RETURNS void
LANGUAGE plpgsql
AS $$
DECLARE
  r record;
  sql_text text;
BEGIN
  FOR r IN
    WITH
      -- Lookup all enforce_overview_rast_oid constraints, parse the main raster table oid
      -- from the constraint expression, return overview schema name, overview table name and
      -- main raster oid
      overview_constraint_oid AS
      (SELECT nsp.nspname o_table_schema ,
              rel.relname o_table_name ,
              substring(pg_get_expr(con.conbin, con.conrelid)
                        FROM '_overview_constraint_oid\(\((\d+)\)::oid\)')::oid AS rast_oid
      FROM pg_catalog.pg_constraint con
      INNER JOIN pg_catalog.pg_class rel ON rel.oid = con.conrelid
      INNER JOIN pg_catalog.pg_namespace nsp ON nsp.oid = connamespace
      WHERE conname = 'enforce_overview_rast_oid'),
      -- Join overview_constraint_oid with pg_class/pg_namespace to include the main raster
      -- schema and table names
      overview_constraint_oid_name AS
      (SELECT o_table_schema,
              o_table_name,
              rast_oid,
              nspname r_table_schema_from_oid,
              relname r_table_name_from_oid
      FROM overview_constraint_oid
      LEFT JOIN pg_catalog.pg_class rel ON rel.oid = overview_constraint_oid.rast_oid
      LEFT JOIN pg_catalog.pg_namespace nsp ON nsp.oid = rel.relnamespace)
    -- List of overviews for which we need to update the enforce_overview_rast constraint based on enforce_overview_rast_oid
    SELECT raster_overviews.*, rast_oid, r_table_schema_from_oid, r_table_name_from_oid
    FROM public.raster_overviews
    LEFT JOIN overview_constraint_oid_name ON (raster_overviews.o_table_schema = overview_constraint_oid_name.o_table_schema
                                              AND raster_overviews.o_table_name = overview_constraint_oid_name.o_table_name)
    WHERE raster_overviews.r_table_schema <> overview_constraint_oid_name.r_table_schema_from_oid
      OR raster_overviews.r_table_name <> overview_constraint_oid_name.r_table_name_from_oid
  LOOP
      RAISE NOTICE 'DropOverviewConstraints(%, %, %)', r.o_table_schema, r.o_table_name, r.o_raster_column;
      PERFORM DropOverviewConstraints(r.o_table_schema, r.o_table_name, r.o_raster_column);
      RAISE NOTICE 'AddOverviewConstraints(%, %, %, %, %, %, %)', r.o_table_schema, r.o_table_name, r.o_raster_column, r.r_table_schema_from_oid, r.r_table_name_from_oid, r.r_raster_column, r.overview_factor;
      PERFORM AddOverviewConstraints(r.o_table_schema, r.o_table_name, r.o_raster_column, r.r_table_schema_from_oid, r.r_table_name_from_oid, r.r_raster_column, r.overview_factor);
  END LOOP;
END;
$$;
COMMENT ON FUNCTION public.update_raster_overview_constraints()
  IS 'Update the enforce_overview_rast constraint for each overview raster based on the oid defined in the enforce_overview_rast_oid constraint.';

-- Update overview constraints for raster overviews after ALTER TABLE
CREATE OR REPLACE FUNCTION raster_alter_end()
RETURNS event_trigger
LANGUAGE plpgsql
AS $$
BEGIN
  -- Avoid recursive calls to this trigger
  IF current_setting('tmp.executing__raster_alter_start', true) = 'true' OR
     current_setting('tmp.executing__raster_alter_end', true) = 'true' THEN
      RETURN;
  END IF;
  PERFORM set_config('tmp.executing__raster_alter_end', 'true', true);
  PERFORM public.update_raster_overview_constraints();
  PERFORM set_config('tmp.executing__raster_alter_end', 'false', true);
END;
$$;

DROP EVENT TRIGGER IF EXISTS trg_raster_alter_end;
CREATE EVENT TRIGGER trg_raster_alter_end ON ddl_command_end
  WHEN tag IN ('ALTER TABLE', 'ALTER SCHEMA')
  EXECUTE PROCEDURE raster_alter_end();

ALTER TABLE uk.os_miniscale RENAME to smallscale;
ALTER TABLE uk.smallscale RENAME to os_miniscale;
SELECT * FROM public.raster_overviews;

