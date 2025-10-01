---
header: 'Automate PostGIS and QGIS using Triggers'
footer: 'mattwalker@astuntechnology.com'
theme: base
---

<style>
section {
  background-image: url('astun-logo.png');
  background-repeat: no-repeat;
  background-position: right top;
}
</style>

# Automate PostGIS and QGIS using Triggers

<sub>https://www.astuntechnology.com</sub>  
<sub>https://mastodon.social/@walkermatt</sub>  

---

During the talk we will look at:
* What **Triggers** are and how to define them
* Using Triggers to maintain the link between **QGIS layers** and their styles in
  the `layer_styles` table
* Retaining the association between **raster overviews** and a main raster table

---

# Triggers

Custom logic executed when something happens within the database.

* "Regular" Triggers on `INSERT`, `DELETE` etc.
* Event Triggers on `CREATE TABLE`, `ALTER TABLE`etc.

---

## "Regular" Triggers

Triggers, are attached to a table or view and react to statements such as `INSERT`, `UPDATE` or `DELETE` (**DML** - Data Manipulation Language)

* Executed `BEFORE`, `AFTER`, or `INSTEAD OF` the statement

* **Example:** maintaining an `updated_at` column

---

## Event Triggers

Custom logic executed when database objects are updated with commands such as `CREATE TABLE`, `ALTER TABLE` etc. (**DDL** - Data Definition Language)

* Event triggers are fired either at the **start** or **end** of a **command**
    * **start** - before any changes are made
    * **end** - changes are made but not committed

* **Example:** setting default privileges for a newly created table

---

# QGIS layer styles

Layer styles can be stored in the database along with the table associated with the layer.

---

## Store layer styles in the database

### QGIS

> Open `uk.venue` in QGIS
> Create a categorised style on `category` column
> Save to datasource database

### pgAdmin

```sql
SELECT * FROM layer_styles;
```

---

## Renaming a table breaks the association with styles in `layer_styles` ☹

### QGIS

> Rename `uk.venue` to `place` via QGIS Browser
> Close `venue` layer, open the `place` layer - styles are missing!

---

This can be fixed manually by updating the `layer_styles` table:
```sql
UPDATE public.layer_styles SET f_table_name = 'place' WHERE f_table_schema = 'uk' AND f_table_name = 'venue';
```

---

# Automatically maintain the association

When a table is renamed, update `f_table_schema` and `f_table_name` columns in `layer_styles` to maintain the association.

---

# Approach

- Alter `layer_styles` to add an `f_table_oid` column to track the `schema` and
  `table` of the associated table regardless of its name
* Create a trigger to maintain the `table_oid` column on `INSERT` or `UPDATE`
* Create an event trigger to update `f_table_schema` and `f_table_name` based on the `f_table_oid` after `ALTER TABLE` or `ALTER SCHEMA`

---

# `oid`s

- An `oid` is an object identifier, used to identify objects in the database
* The `oid` of a table stays the same even if it is renamed or moved to a different schema

---

## Add `table_oid` column to `layer_styles`

```sql
ALTER TABLE public.layer_styles ADD COLUMN IF NOT EXISTS table_oid oid;

UPDATE public.layer_styles SET table_oid =
    to_regclass(quote_ident(f_table_schema) || '.' || quote_ident(f_table_name))::oid;

SELECT table_oid, * FROM public.layer_styles;
```

The [`to_regclass(text)` function][to_regclass] translates a textual relation name such as `uk.place` to its `oid`

[to_regclass]: https://www.postgresql.org/docs/17/functions-info.html#:~:text=to_regclass%20(%20text%20)

---

## Maintain `table_oid` with a trigger

Create a trigger to maintain the `table_oid` column on `INSERT` or `UPDATE`

```sql
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
```

---

The `layer_styles_table_oid` trigger and associated function ensure that the
`table_oid` value is populated for newly inserted and updated rows.

## QGIS

>  Create a **new style** for the `uk.place` layer and **save "In datasource database"**

## pgAdmin

```sql
SELECT table_oid, * FROM public.layer_styles;
```

---

#### Update `f_table_schema` and `f_table_name` with an event trigger

```sql
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
```

---

The `event_trigger` function is executed on `ddl_command_end` when an `ALTER TABLE` or `ALTER SCHEMA` DDL command has been executed, the actions have taken place (but before the transaction commits)
```sql
DROP EVENT TRIGGER IF EXISTS trg_alter_table;
CREATE EVENT TRIGGER trg_alter_table
    ON ddl_command_end
    WHEN TAG IN ('ALTER TABLE', 'ALTER SCHEMA')
    EXECUTE FUNCTION on_alter_table();
```

---

Event triggers are fairly coarse-grained - we know that an `ALTER TABLE` statement was executed but not whether it was `ALTER TABLE x.a RENAME to b;`, `ALTER TABLE x.a SET SCHEMA y;`  or `ALTER TABLE x.a ADD COLUMN z integer;` etc.
<br />
Event trigger functions shouldn't do too much to avoid impacting performance

---

Within an event trigger calling `pg_event_trigger_ddl_commands()` provides a
list of DDL commands that caused the trigger function to be executed.

```sql
...
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
...
```

---

```sql
...
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
...
```

- We are using the following ddl command properties:
    * `object_type` We check for `TABLE` or `SCHEMA`, ignoring `COLUMN` etc.
    * `object_identity` name of the object (table or schema) being altered
    * `schema_name` the schema which the object belongs to
    * `objid` the `oid` of the object being altered

---

# Testing...

## QGIS

> Rename `uk.place` to `venue` via QGIS Browser
> Open the `venue` layer - styles are present 🎉
  

## pgAdmin

```sql
SELECT table_oid, * FROM public.layer_styles;
```

The same applies for `ALTER SCHEMA uk RENAME TO gb;` and `ALTER TABLE gb.venue SET SCHEMA public;`

---

# Raster data

Raster data can be stored in PostgreSQL using the `postgis_raster` extension.

> In a nutshell, a raster is a matrix, pinned on a coordinate system, that has values that can represent anything you want them to represent. - https://postgis.net/workshops/postgis-intro/rasters.html

---

# Raster data

Raster data is commonly imported via the `raster2pgsql` command line tool which uses GDAL to read the source data (`GeoTIFF`, `DEM` etc.)

Raster data stored in PostgreSQL can be used for visualisation and analysis by QGIS, GDAL etc.

---

## Raster overviews

PostGIS supports creating **overviews** which are **lower resolution** versions of the main raster table which speed up viewing when zoomed out.

Overviews are stored in separate tables following a naming convension and are associated with the main raster via a constraint.

---

```sql
-- Equivalent of geometry_columns
SELECT * FROM raster_columns;

-- Overview raster tables
SELECT * FROM raster_overviews;
```

---

## Overviews can be orphaned

If the main raster table is **renamed** the association with its overviews is broken ☹

The association is made via a constraint on each overview which references the `schema` and `table` of the main raster.

```sql
CREATE TABLE IF NOT EXISTS uk.o_2_os_miniscale
(
    rid integer NOT NULL DEFAULT nextval('uk.o_2_os_miniscale_rid_seq'::regclass),
    rast raster,
    ...
    CONSTRAINT enforce_overview_rast CHECK (_overview_constraint(rast, 2, 'uk'::name, 'os_miniscale'::name, 'rast'::name)),
    ...
);
```

---

## Automatically maintain the association

Update the `enforce_overview_rast` constraint when the main raster is renamed.

---

## Approach

- Define a `_overview_constraint_oid(r_table_oid oid)` function to record the `oid` of the main raster associated with an overview
* Add a `CONSTRAINT` to each overview using `_overview_constraint_oid(r_table_oid oid)` to track the main raster
* When a main raster is renamed, use an event trigger to update `enforce_overview_rast` on the overview (which tracks the `schema` and `table`)

---

```sql
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
```

---

```sql
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
```

---


Get a list of raster overviews with their `oid` if they have an `enforce_overview_rast_oid` `CONSTRAINT`
```sql
    ...
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
    ...
```

---

Loop over the overviews, add `enforce_overview_rast_oid` `CONSTRAINT` if needed
```sql
  ...
  LOOP
      BEGIN
        rast_oid = regclass(quote_ident(r.r_table_schema) || '.' || quote_ident(r.r_table_name))::oid;
        EXCEPTION WHEN SQLSTATE '42704' OR SQLSTATE '3F000' THEN
          RAISE WARNING 'SQLSTATE: %; ERROR: %; Unable to add CONSTRAINT enforce_overview_rast_oid.', SQLSTATE, SQLERRM;
          CONTINUE;
      END;
      -- Only update the enforce_overview_rast_oid constraint if needed
      IF rast_oid IS NOT NULL AND rast_oid IS DISTINCT FROM r.rast_oid THEN
        RAISE NOTICE 'rast_oid: %, r.rast_oid: %', rast_oid, r.rast_oid;
        sql_text = format('ALTER TABLE %I.%I DROP CONSTRAINT IF EXISTS enforce_overview_rast_oid;', r.o_table_schema, r.o_table_name);
        RAISE NOTICE '%', sql_text;
        EXECUTE sql_text;
        sql_text = format('ALTER TABLE %I.%I ADD CONSTRAINT enforce_overview_rast_oid CHECK (public._overview_constraint_oid(%s::oid)) NOT VALID;',
                            r.o_table_schema, r.o_table_name, rast_oid);
        RAISE NOTICE '%', sql_text;
        EXECUTE sql_text;
      END IF;
  END LOOP;
  ...
```

---

```sql
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
```

---

```sql
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
```

---

Overviews for which the `rast_oid` doesn't match the `r_table_schema.r_table_name`
```sql
...
WITH
  overview_constraint_oid AS
  (SELECT nsp.nspname o_table_schema ,
          rel.relname o_table_name ,
          substring(pg_get_expr(con.conbin, con.conrelid)
                    FROM '_overview_constraint_oid\(\((\d+)\)::oid\)')::oid AS rast_oid
  FROM pg_catalog.pg_constraint con
  INNER JOIN pg_catalog.pg_class rel ON rel.oid = con.conrelid
  INNER JOIN pg_catalog.pg_namespace nsp ON nsp.oid = connamespace
  WHERE conname = 'enforce_overview_rast_oid'),
  overview_constraint_oid_name AS
  (SELECT o_table_schema,
          o_table_name,
          rast_oid,
          nspname r_table_schema_from_oid,
          relname r_table_name_from_oid
  FROM overview_constraint_oid
  LEFT JOIN pg_catalog.pg_class rel ON rel.oid = overview_constraint_oid.rast_oid
  LEFT JOIN pg_catalog.pg_namespace nsp ON nsp.oid = rel.relnamespace)
SELECT raster_overviews.*, rast_oid, r_table_schema_from_oid, r_table_name_from_oid
FROM public.raster_overviews
LEFT JOIN overview_constraint_oid_name ON (raster_overviews.o_table_schema = overview_constraint_oid_name.o_table_schema
                                          AND raster_overviews.o_table_name = overview_constraint_oid_name.o_table_name)
WHERE raster_overviews.r_table_schema <> overview_constraint_oid_name.r_table_schema_from_oid
  OR raster_overviews.r_table_name <> overview_constraint_oid_name.r_table_name_from_oid
...
```

---

Update the overview constraint
```sql
...
LOOP
    PERFORM DropOverviewConstraints(r.o_table_schema, r.o_table_name, r.o_raster_column);
    PERFORM AddOverviewConstraints(r.o_table_schema, r.o_table_name, r.o_raster_column,
                                   r.r_table_schema_from_oid, r.r_table_name_from_oid,
                                   r.r_raster_column, r.overview_factor);
END LOOP;
...
```
---

```sql
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
```

---

# Testing

```sql
ALTER TABLE uk.os_miniscale RENAME to smallscale;
ALTER TABLE uk.smallscale RENAME to os_miniscale;
SELECT * FROM public.raster_overviews;
```

---

# Reference

- [This talk and code on GitHub](https://github.com/walkermatt/foss4g-uk-2025-postgis-qgis-triggers)
    - walkermatt/foss4g-uk-2025-postgis-qgis-triggers
- ["Regular" Triggers (DML)](https://www.postgresql.org/docs/17/trigger-definition.html)
- [Event Triggers (DDL)](https://www.postgresql.org/docs/17/trigger-definition.html)
