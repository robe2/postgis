--
-- PostGIS - Spatial Types for PostgreSQL
-- http://postgis.net
--
-- Copyright (C) 2012-2024 Regina Obe and Leo Hsu
-- Paragon Corporation
--
-- This is free software; you can redistribute and/or modify it under
-- the terms of the GNU General Public Licence. See the COPYING file.
--
-- Author: Regina Obe and Leo Hsu <lr@pcorp.us>
--
-- - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - -
SELECT tiger.SetSearchPathForInstall('tiger');
BEGIN;
CREATE OR REPLACE FUNCTION create_census_base_tables()
	RETURNS text AS
$$
DECLARE var_temp text;
BEGIN
var_temp := tiger.SetSearchPathForInstall('tiger');
IF NOT EXISTS(SELECT table_name FROM information_schema.columns WHERE table_schema = 'tiger' AND column_name = 'tract_id' AND table_name = 'tract')  THEN
	-- census block group/tracts parent tables not created yet or an older version -- drop old if not in use, create new structure
	DROP TABLE IF EXISTS tiger.tract;
	CREATE TABLE tract
	(
	  gid serial NOT NULL,
	  statefp varchar(2),
	  countyfp varchar(3),
	  tractce varchar(6),
	  tract_id varchar(11) PRIMARY KEY,
	  name varchar(7),
	  namelsad varchar(20),
	  mtfcc varchar(5),
	  funcstat varchar(1),
	  aland double precision,
	  awater double precision,
	  intptlat varchar(11),
	  intptlon varchar(12),
	  the_geom geometry,
	  CONSTRAINT enforce_dims_geom CHECK (st_ndims(the_geom) = 2),
	  CONSTRAINT enforce_geotype_geom CHECK (geometrytype(the_geom) = 'MULTIPOLYGON'::text OR the_geom IS NULL),
	  CONSTRAINT enforce_srid_geom CHECK (st_srid(the_geom) = 4269)
	);

	DROP TABLE IF EXISTS tiger.tabblock;
	CREATE TABLE tabblock
	(
	  gid serial NOT NULL,
	  statefp varchar(2),
	  countyfp varchar(3),
	  tractce varchar(6),
	  blockce varchar(4),
	  tabblock_id varchar(16) PRIMARY KEY,
	  name varchar(20),
	  mtfcc varchar(5),
	  ur varchar(1),
	  uace varchar(5),
	  funcstat varchar(1),
	  aland double precision,
	  awater double precision,
	  intptlat varchar(11),
	  intptlon varchar(12),
	  the_geom geometry,
	  CONSTRAINT enforce_dims_geom CHECK (st_ndims(the_geom) = 2),
	  CONSTRAINT enforce_geotype_geom CHECK (geometrytype(the_geom) = 'MULTIPOLYGON'::text OR the_geom IS NULL),
	  CONSTRAINT enforce_srid_geom CHECK (st_srid(the_geom) = 4269)
	);

	DROP TABLE IF EXISTS tiger.bg;
	CREATE TABLE bg
	(
	  gid serial NOT NULL,
	  statefp varchar(2),
	  countyfp varchar(3),
	  tractce varchar(6),
	  blkgrpce varchar(1),
	  bg_id varchar(12) PRIMARY KEY,
	  namelsad varchar(13),
	  mtfcc varchar(5),
	  funcstat varchar(1),
	  aland double precision,
	  awater double precision,
	  intptlat varchar(11),
	  intptlon varchar(12),
	  the_geom geometry,
	  CONSTRAINT enforce_dims_geom CHECK (st_ndims(the_geom) = 2),
	  CONSTRAINT enforce_geotype_geom CHECK (geometrytype(the_geom) = 'MULTIPOLYGON'::text OR the_geom IS NULL),
	  CONSTRAINT enforce_srid_geom CHECK (st_srid(the_geom) = 4269)
	);
	COMMENT ON TABLE tiger.bg IS 'block groups';
END IF;

IF EXISTS(SELECT * FROM information_schema.columns WHERE table_schema = 'tiger' AND column_name = 'tabblock_id' AND table_name = 'tabblock' AND character_maximum_length < 16)  THEN -- size of name and tabblock_id fields need to be increased
    ALTER TABLE tiger.tabblock ALTER COLUMN name TYPE varchar(20);
    ALTER TABLE tiger.tabblock ALTER COLUMN tabblock_id TYPE varchar(16);
    RAISE NOTICE 'Size of tabblock_id and name are being increased';
END IF;
RETURN 'Tables already present';
END
$$
language 'plpgsql';

CREATE OR REPLACE FUNCTION loader_macro_replace(param_input text, param_keys text[],param_values text[])
RETURNS text AS
$$
	DECLARE var_result text = param_input;
	DECLARE var_count integer = array_upper(param_keys,1);
	BEGIN
		FOR i IN 1..var_count LOOP
			var_result := replace(var_result, '${' || param_keys[i] || '}', param_values[i]);
		END LOOP;
		return var_result;
	END;
$$
  LANGUAGE 'plpgsql' IMMUTABLE
  COST 100;

CREATE TABLE IF NOT EXISTS tiger.tabblock20
(
    statefp character varying(2) ,
    countyfp character varying(3) ,
    tractce character varying(6) ,
    blockce character varying(4) ,
    geoid character varying(15) ,
    name character varying(10) ,
    mtfcc character varying(5) ,
    ur character varying(1) ,
    uace character varying(5) ,
    uatype character varying(1) ,
    funcstat character varying(1) ,
    aland double precision,
    awater double precision,
    intptlat character varying(11) ,
    intptlon character varying(12) ,
    the_geom geometry(MultiPolygon,4269), housing float, pop float,
    CONSTRAINT pk_tabblock20 PRIMARY KEY (geoid)
);

ALTER TABLE tiger.faces ADD IF NOT EXISTS tractce20 varchar(6);
ALTER TABLE tiger.faces ADD IF NOT EXISTS blkgrpce20 varchar(1);
ALTER TABLE tiger.faces ADD IF NOT EXISTS blockce20  varchar(4);
ALTER TABLE tiger.faces ADD IF NOT EXISTS countyfp20 varchar(3);
ALTER TABLE tiger.faces ADD IF NOT EXISTS statefp20 varchar(2);

ALTER TABLE tiger.tabblock20 ADD IF NOT EXISTS housing float;
ALTER TABLE tiger.tabblock20 ADD IF NOT EXISTS pop float;


-- Helper function that generates script to drop all tables in a particular schema for a particular table
-- This is useful in case you need to reload a state
CREATE OR REPLACE FUNCTION drop_state_tables_generate_script(param_state text, param_schema text DEFAULT 'tiger_data')
  RETURNS text AS
$$
SELECT array_to_string(array_agg('DROP TABLE ' || quote_ident(table_schema) || '.' || quote_ident(table_name) || ';'),E'\n')
	FROM (SELECT * FROM information_schema.tables
	WHERE table_schema = $2 AND table_name like lower($1) || '~_%' ESCAPE '~' ORDER BY table_name) AS foo;
;
$$
  LANGUAGE sql VOLATILE;

-- Helper function that generates script to drop all nation tables (county, state) in a particular schema
-- This is useful for loading 2011 because state and county tables aren't broken out into separate state files
DROP FUNCTION IF EXISTS drop_national_tables_generate_script(text);
CREATE OR REPLACE FUNCTION drop_nation_tables_generate_script(param_schema text DEFAULT 'tiger_data')
  RETURNS text AS
$$
SELECT array_to_string(array_agg('DROP TABLE ' || quote_ident(table_schema) || '.' || quote_ident(table_name) || ';'),E'\n')
	FROM (SELECT * FROM information_schema.tables
	WHERE table_schema = $1 AND (table_name ~ E'^[a-z]{2}\_county' or table_name ~ E'^[a-z]{2}\_state' or table_name = 'state_all' or table_name LIKE 'county_all%' or table_name LIKE 'zcta5_all%') ORDER BY table_name) AS foo;
;
$$
  LANGUAGE sql VOLATILE;

DO
$$
BEGIN
  IF NOT EXISTS (SELECT * FROM information_schema.tables WHERE table_name = 'loader_platform' AND table_schema = 'tiger') THEN
      CREATE TABLE loader_platform(os varchar(50) PRIMARY KEY, declare_sect text, pgbin text, wget text, unzip_command text, psql text, path_sep text, loader text, environ_set_command text, county_process_command text);
  END IF;
END
$$ LANGUAGE 'plpgsql';

DO
$$
BEGIN
  IF NOT EXISTS (SELECT * FROM information_schema.schemata WHERE schema_name = 'tiger_data') THEN
       CREATE SCHEMA tiger_data;
  END IF;
END
$$ LANGUAGE 'plpgsql';

DELETE FROM loader_platform WHERE os IN ('sh', 'windows');
GRANT SELECT ON TABLE loader_platform TO public;
INSERT INTO loader_platform(os, wget, pgbin, declare_sect, unzip_command, psql,path_sep,loader, environ_set_command, county_process_command)
VALUES('windows', '%WGETTOOL%', '%PGBIN%',
E'set TMPDIR=${staging_fold}\\temp\\
set UNZIPTOOL="C:\\Program Files\\7-Zip\\7z.exe"
set WGETTOOL="C:\\wget\\wget.exe"
set PGBIN=C:\\Program Files\\PostgreSQL\\16\\bin\\
set PGPORT=5432
set PGHOST=localhost
set PGUSER=postgres
set PGPASSWORD=yourpasswordhere
set PGDATABASE=geocoder
set PSQL="%PGBIN%psql"
set SHP2PGSQL="%PGBIN%shp2pgsql"
cd ${staging_fold}
', E'del %TMPDIR%\\*.* /Q
%PSQL% -c "DROP SCHEMA IF EXISTS ${staging_schema} CASCADE;"
%PSQL% -c "CREATE SCHEMA ${staging_schema};"
%PSQL% -c "DO language ''plpgsql'' $$ BEGIN IF NOT EXISTS (SELECT * FROM information_schema.schemata WHERE schema_name = ''${data_schema}'' ) THEN CREATE SCHEMA ${data_schema}; END IF;  END $$"
for /r %%z in (*.zip) do %UNZIPTOOL% e %%z  -o%TMPDIR%
cd %TMPDIR%', E'%PSQL%', E'\\', E'%SHP2PGSQL%', 'set ',
'for /r %%z in (*${table_name}*.dbf) do (${loader} -D -s 4269 -g the_geom -W "latin1" %%z tiger_staging.${state_abbrev}_${table_name} | ${psql} & ${psql} -c "SELECT loader_load_staged_data(lower(''${state_abbrev}_${table_name}''), lower(''${state_abbrev}_${lookup_name}''));")'
);

INSERT INTO loader_platform(os, wget, pgbin, declare_sect, unzip_command, psql, path_sep, loader, environ_set_command, county_process_command)
VALUES('sh', 'wget', '',
E'TMPDIR="${staging_fold}/temp/"
UNZIPTOOL=unzip
WGETTOOL="/usr/bin/wget"
export PGBIN=/usr/lib/postgresql/16/bin
export PGPORT=5432
export PGHOST=localhost
export PGUSER=postgres
export PGPASSWORD=yourpasswordhere
export PGDATABASE=geocoder
PSQL=${PGBIN}/psql
SHP2PGSQL=shp2pgsql
cd ${staging_fold}
', E'rm -f ${TMPDIR}/*.*
${PSQL} -c "DROP SCHEMA IF EXISTS ${staging_schema} CASCADE;"
${PSQL} -c "CREATE SCHEMA ${staging_schema};"
for z in *.zip; do $UNZIPTOOL -o -d $TMPDIR $z; done
cd $TMPDIR;\n', '${PSQL}', '/', '${SHP2PGSQL}', 'export ',
'for z in *${table_name}*.dbf; do
${loader} -D -s 4269 -g the_geom -W "latin1" $z ${staging_schema}.${state_abbrev}_${table_name} | ${psql}
${PSQL} -c "SELECT loader_load_staged_data(lower(''${state_abbrev}_${table_name}''), lower(''${state_abbrev}_${lookup_name}''));"
done');

-- variables table
DO $$
BEGIN
  IF NOT EXISTS (SELECT * FROM information_schema.tables WHERE table_name = 'loader_variables' AND table_schema = 'tiger') THEN
      CREATE TABLE loader_variables(tiger_year varchar(4) PRIMARY KEY, website_root text, staging_fold text, data_schema text, staging_schema text);
  END IF;
END
$$ LANGUAGE 'plpgsql';

TRUNCATE TABLE loader_variables;
INSERT INTO loader_variables(tiger_year, website_root , staging_fold, data_schema, staging_schema)
	VALUES('2024', 'https://www2.census.gov/geo/tiger/TIGER2024', '/gisdata', 'tiger_data', 'tiger_staging');
GRANT SELECT ON TABLE loader_variables TO public;

DO $$
BEGIN
  IF NOT EXISTS (SELECT * FROM information_schema.tables WHERE table_name = 'loader_lookuptables' AND table_schema = 'tiger') THEN
   CREATE TABLE loader_lookuptables(process_order integer NOT NULL DEFAULT 1000,
		lookup_name text primary key,
		table_name text, single_mode boolean NOT NULL DEFAULT true,
		load boolean NOT NULL DEFAULT true,
		level_county boolean NOT NULL DEFAULT false,
		level_state boolean NOT NULL DEFAULT false,
		level_nation boolean NOT NULL DEFAULT false,
		post_load_process text, single_geom_mode boolean DEFAULT false,
		insert_mode char(1) NOT NULL DEFAULT 'c',
		pre_load_process text,columns_exclude text[], website_root_override text);
  END IF;
END
$$ LANGUAGE 'plpgsql';

TRUNCATE TABLE loader_lookuptables;

GRANT SELECT ON TABLE loader_lookuptables TO public;

-- put in explanatory comments of what each column is for
COMMENT ON COLUMN loader_lookuptables.lookup_name IS 'This is the table name to inherit from and suffix of resulting output table -- how the table will be named --  edges here would mean -- ma_edges , pa_edges etc. except in the case of national tables. national level tables have no prefix';
COMMENT ON COLUMN loader_lookuptables.level_nation IS 'These are tables that contain all data for the whole US so there is just a single file';
COMMENT ON COLUMN loader_lookuptables.table_name IS 'suffix of the tables to load e.g.  edges would load all tables like *edges.dbf(shp)  -- so tl_2010_42129_edges.dbf .  ';
COMMENT ON COLUMN loader_lookuptables.load IS 'Whether or not to load the table.  For states and zcta5 (you may just want to download states10, zcta510 nationwide file manually) load your own into a single table that inherits from tiger.states, tiger.zcta5.  You''ll get improved performance for some geocoding cases.';
COMMENT ON COLUMN loader_lookuptables.columns_exclude IS 'List of columns to exclude as an array. This is excluded from both input table and output table and rest of columns remaining are assumed to be in same order in both tables. gid, geoid,cpi,suffix1ce are excluded if no columns are specified.';
COMMENT ON COLUMN loader_lookuptables.website_root_override IS 'Path to use for wget instead of that specified in year table.  Needed currently for zcta where they release that only for 2000 and 2010';

INSERT INTO loader_lookuptables(process_order, lookup_name, table_name, load, level_county, level_state, single_geom_mode, insert_mode, pre_load_process, post_load_process, columns_exclude )
VALUES(10, 'tract', 'tract', true, false, true,false, 'c',
'${psql} -c "CREATE TABLE ${data_schema}.${state_abbrev}_${lookup_name}(CONSTRAINT pk_${state_abbrev}_${lookup_name} PRIMARY KEY (tract_id) ) INHERITS(tiger.${lookup_name}); " ',
	'${psql} -c "ALTER TABLE ${staging_schema}.${state_abbrev}_${table_name} RENAME geoid TO tract_id; SELECT loader_load_staged_data(lower(''${state_abbrev}_${table_name}''), lower(''${state_abbrev}_${lookup_name}'')); "
	${psql} -c "CREATE INDEX ${data_schema}_${state_abbrev}_${lookup_name}_the_geom_gist ON ${data_schema}.${state_abbrev}_${lookup_name} USING gist(the_geom);"
	${psql} -c "VACUUM ANALYZE ${data_schema}.${state_abbrev}_${lookup_name};"
	${psql} -c "ALTER TABLE ${data_schema}.${state_abbrev}_${lookup_name} ADD CONSTRAINT chk_statefp CHECK (statefp = ''${state_fips}'');"', ARRAY['gid', 'geoidfq']);

INSERT INTO loader_lookuptables(process_order, lookup_name, table_name, load, level_county, level_state, single_geom_mode, insert_mode, pre_load_process, post_load_process, columns_exclude )
VALUES(11, 'tabblock20', 'tabblock20', true, false, true,false, 'c',
'${psql} -c "CREATE TABLE ${data_schema}.${state_abbrev}_${lookup_name}(CONSTRAINT pk_${state_abbrev}_${lookup_name} PRIMARY KEY (geoid)) INHERITS(tiger.${lookup_name});" ',
'${psql} -c "SELECT loader_load_staged_data(lower(''${state_abbrev}_${table_name}''), lower(''${state_abbrev}_${lookup_name}'')); "
${psql} -c "ALTER TABLE ${data_schema}.${state_abbrev}_${lookup_name} ADD CONSTRAINT chk_statefp CHECK (statefp = ''${state_fips}'');"
${psql} -c "CREATE INDEX ${data_schema}_${state_abbrev}_${lookup_name}_the_geom_gist ON ${data_schema}.${state_abbrev}_${lookup_name} USING gist(the_geom);"
${psql} -c "vacuum analyze ${data_schema}.${state_abbrev}_${lookup_name};"', '{gid, geoidfq20, uatype}'::text[]);

INSERT INTO loader_lookuptables(process_order, lookup_name, table_name, load, level_county, level_state, single_geom_mode, insert_mode, pre_load_process, post_load_process, columns_exclude )
VALUES(12, 'bg', 'bg', false,false, true,false, 'c',
'${psql} -c "CREATE TABLE ${data_schema}.${state_abbrev}_${lookup_name}(CONSTRAINT pk_${state_abbrev}_${lookup_name} PRIMARY KEY (bg_id)) INHERITS(tiger.${lookup_name});" ',
'${psql} -c "ALTER TABLE ${staging_schema}.${state_abbrev}_${table_name} RENAME geoid TO bg_id;  SELECT loader_load_staged_data(lower(''${state_abbrev}_${table_name}''), lower(''${state_abbrev}_${lookup_name}'')); "
${psql} -c "ALTER TABLE ${data_schema}.${state_abbrev}_${lookup_name} ADD CONSTRAINT chk_statefp CHECK (statefp = ''${state_fips}'');"
${psql} -c "CREATE INDEX ${data_schema}_${state_abbrev}_${lookup_name}_the_geom_gist ON ${data_schema}.${state_abbrev}_${lookup_name} USING gist(the_geom);"
${psql} -c "vacuum analyze ${data_schema}.${state_abbrev}_${lookup_name};"', ARRAY['gid', 'geoidfq']);

INSERT INTO loader_lookuptables(process_order, lookup_name, table_name, load, level_county, level_state,  level_nation, single_geom_mode, pre_load_process, post_load_process)
VALUES(2, 'county_all', 'county', true, false, false, true,
	false, '${psql} -c "CREATE TABLE ${data_schema}.${lookup_name}(CONSTRAINT pk_${data_schema}_${lookup_name} PRIMARY KEY (cntyidfp),CONSTRAINT uidx_${data_schema}_${lookup_name}_gid UNIQUE (gid)  ) INHERITS(tiger.county); " ',
	'${psql} -c "ALTER TABLE ${staging_schema}.${table_name} RENAME geoid TO cntyidfp;  SELECT loader_load_staged_data(lower(''${table_name}''), lower(''${lookup_name}''));"
	${psql} -c "CREATE INDEX ${data_schema}_${table_name}_the_geom_gist ON ${data_schema}.${lookup_name} USING gist(the_geom);"
	${psql} -c "CREATE UNIQUE INDEX uidx_${data_schema}_${lookup_name}_statefp_countyfp ON ${data_schema}.${lookup_name} USING btree(statefp,countyfp);"
	${psql} -c "CREATE TABLE ${data_schema}.${lookup_name}_lookup ( CONSTRAINT pk_${lookup_name}_lookup PRIMARY KEY (st_code, co_code)) INHERITS (tiger.county_lookup);"
	${psql} -c "VACUUM ANALYZE ${data_schema}.${lookup_name};"
	${psql} -c "INSERT INTO ${data_schema}.${lookup_name}_lookup(st_code, state, co_code, name) SELECT CAST(s.statefp as integer), s.abbrev, CAST(c.countyfp as integer), c.name FROM ${data_schema}.${lookup_name} As c INNER JOIN state_lookup As s ON s.statefp = c.statefp;"
	${psql} -c "VACUUM ANALYZE ${data_schema}.${lookup_name}_lookup;" ');

INSERT INTO loader_lookuptables(process_order, lookup_name, table_name, load, level_county, level_state, level_nation, single_geom_mode, insert_mode, pre_load_process, post_load_process )
VALUES(1, 'state_all', 'state', true, false, false,true,false, 'c',
	'${psql} -c "CREATE TABLE ${data_schema}.${lookup_name}(CONSTRAINT pk_${lookup_name} PRIMARY KEY (statefp),CONSTRAINT uidx_${lookup_name}_stusps  UNIQUE (stusps), CONSTRAINT uidx_${lookup_name}_gid UNIQUE (gid) ) INHERITS(tiger.state); "',
	'${psql} -c "SELECT loader_load_staged_data(lower(''${table_name}''), lower(''${lookup_name}'')); "
	${psql} -c "CREATE INDEX ${data_schema}_${lookup_name}_the_geom_gist ON ${data_schema}.${lookup_name} USING gist(the_geom);"
	${psql} -c "VACUUM ANALYZE ${data_schema}.${lookup_name}"' );

INSERT INTO loader_lookuptables(process_order, lookup_name, table_name, load, level_county, level_state, single_geom_mode, insert_mode, pre_load_process, post_load_process )
VALUES(3, 'place', 'place', true, false, true,false, 'c',
	'${psql} -c "CREATE TABLE ${data_schema}.${state_abbrev}_${lookup_name}(CONSTRAINT pk_${state_abbrev}_${table_name} PRIMARY KEY (plcidfp) ) INHERITS(tiger.place);" ',
	'${psql} -c "ALTER TABLE ${staging_schema}.${state_abbrev}_${table_name} RENAME geoid TO plcidfp;SELECT loader_load_staged_data(lower(''${state_abbrev}_${table_name}''), lower(''${state_abbrev}_${lookup_name}'')); ALTER TABLE ${data_schema}.${state_abbrev}_${lookup_name} ADD CONSTRAINT uidx_${state_abbrev}_${lookup_name}_gid UNIQUE (gid);"
${psql} -c "CREATE INDEX idx_${state_abbrev}_${lookup_name}_soundex_name ON ${data_schema}.${state_abbrev}_${lookup_name} USING btree (soundex(name));"
${psql} -c "CREATE INDEX ${data_schema}_${state_abbrev}_${lookup_name}_the_geom_gist ON ${data_schema}.${state_abbrev}_${lookup_name} USING gist(the_geom);"
${psql} -c "ALTER TABLE ${data_schema}.${state_abbrev}_${lookup_name} ADD CONSTRAINT chk_statefp CHECK (statefp = ''${state_fips}'');"'
	);

INSERT INTO loader_lookuptables(process_order, lookup_name, table_name, load, level_county, level_state, single_geom_mode, insert_mode, pre_load_process, post_load_process )
VALUES(4, 'cousub', 'cousub', true, false, true,false, 'c',
	'${psql} -c "CREATE TABLE ${data_schema}.${state_abbrev}_${lookup_name}(CONSTRAINT pk_${state_abbrev}_${lookup_name} PRIMARY KEY (cosbidfp), CONSTRAINT uidx_${state_abbrev}_${lookup_name}_gid UNIQUE (gid)) INHERITS(tiger.${lookup_name});" ',
	'${psql} -c "ALTER TABLE ${staging_schema}.${state_abbrev}_${table_name} RENAME geoid TO cosbidfp;SELECT loader_load_staged_data(lower(''${state_abbrev}_${table_name}''), lower(''${state_abbrev}_${lookup_name}'')); ALTER TABLE ${data_schema}.${state_abbrev}_${lookup_name} ADD CONSTRAINT chk_statefp CHECK (statefp = ''${state_fips}'');"
${psql} -c "CREATE INDEX ${data_schema}_${state_abbrev}_${lookup_name}_the_geom_gist ON ${data_schema}.${state_abbrev}_${lookup_name} USING gist(the_geom);"
${psql} -c "CREATE INDEX idx_${data_schema}_${state_abbrev}_${lookup_name}_countyfp ON ${data_schema}.${state_abbrev}_${lookup_name} USING btree(countyfp);"');

INSERT INTO loader_lookuptables(process_order, lookup_name, table_name, load, level_county, level_state, level_nation, single_geom_mode, insert_mode, pre_load_process, post_load_process, columns_exclude )
VALUES(13, 'zcta5_raw', 'zcta520', false,false, false,true, false, 'c',
	'${psql} -c "CREATE TABLE ${data_schema}.${lookup_name}( zcta5 character varying(5), classfp character varying(2),mtfcc character varying(5), funcstat character varying(1), aland double precision, awater double precision, intptlat character varying(11), intptlon character varying(12), the_geom geometry(MultiPolygon,4269) );"',
$post_load$${psql} -c "ALTER TABLE tiger.zcta5 DROP CONSTRAINT IF EXISTS enforce_geotype_the_geom; CREATE TABLE ${data_schema}.zcta5_all(CONSTRAINT pk_zcta5_all PRIMARY KEY (zcta5ce,statefp), CONSTRAINT uidx_${lookup_name}_all_gid UNIQUE (gid)) INHERITS(tiger.zcta5);"
${psql} -c "SELECT loader_load_staged_data(lower('${table_name}'), lower('${lookup_name}'));"
${psql} -c "INSERT INTO ${data_schema}.zcta5_all(statefp, zcta5ce, classfp, mtfcc, funcstat, aland, awater, intptlat, intptlon, partflg, the_geom) SELECT  s.statefp, z.zcta5,  z.classfp, z.mtfcc, z.funcstat, z.aland, z.awater, z.intptlat, z.intptlon, CASE WHEN ST_Covers(s.the_geom, z.the_geom) THEN 'N' ELSE 'Y' END, ST_SnapToGrid(ST_Transform(CASE WHEN ST_Covers(s.the_geom, z.the_geom) THEN ST_SimplifyPreserveTopology(ST_Transform(z.the_geom,2163),1000) ELSE ST_SimplifyPreserveTopology(ST_Intersection(ST_Transform(s.the_geom,2163), ST_Transform(z.the_geom,2163)),1000)  END,4269), 0.000001) As geom FROM ${data_schema}.zcta5_raw AS z INNER JOIN tiger.state AS s ON (ST_Covers(s.the_geom, z.the_geom) or ST_Overlaps(s.the_geom, z.the_geom) );"
	${psql} -c "DROP TABLE ${data_schema}.zcta5_raw; CREATE INDEX idx_${data_schema}_zcta5_all_the_geom_gist ON ${data_schema}.zcta5_all USING gist(the_geom);"$post_load$
, ARRAY['gid','geoid','geoid10', 'geoid20', 'geoidfq20', 'partflg']);

INSERT INTO loader_lookuptables(process_order, lookup_name, table_name, load, level_county, level_state, single_geom_mode, insert_mode, pre_load_process, post_load_process, columns_exclude )
VALUES(6, 'faces', 'faces', true, true, false,false, 'c',
	'${psql} -c "CREATE TABLE ${data_schema}.${state_abbrev}_${table_name}(CONSTRAINT pk_${state_abbrev}_${lookup_name} PRIMARY KEY (gid)) INHERITS(tiger.${lookup_name});" ',
	'${psql} -c "CREATE INDEX ${data_schema}_${state_abbrev}_${table_name}_the_geom_gist ON ${data_schema}.${state_abbrev}_${lookup_name} USING gist(the_geom);"
	${psql} -c "CREATE INDEX idx_${data_schema}_${state_abbrev}_${lookup_name}_tfid ON ${data_schema}.${state_abbrev}_${lookup_name} USING btree (tfid);"
	${psql} -c "CREATE INDEX idx_${data_schema}_${state_abbrev}_${table_name}_countyfp ON ${data_schema}.${state_abbrev}_${table_name} USING btree (countyfp);"
	${psql} -c "ALTER TABLE ${data_schema}.${state_abbrev}_${lookup_name} ADD CONSTRAINT chk_statefp CHECK (statefp = ''${state_fips}'');"
	${psql} -c "vacuum analyze ${data_schema}.${state_abbrev}_${lookup_name};"', ARRAY['gid', 'geoid','geoidfq', 'cpi','suffix1ce', 'statefp00', 'statefp10', 'countyfp00','countyfp10'
   ,'tractce00','tractce10', 'blkgrpce00', 'blkgrpce10', 'blockce00', 'blockce10'
      , 'cousubfp00', 'submcdfp00', 'conctyfp00', 'placefp00', 'aiannhfp00', 'aiannhce00',
       'comptyp00', 'trsubfp00', 'trsubce00', 'anrcfp00', 'elsdlea00', 'scsdlea00',
       'unsdlea00', 'uace00', 'cd108fp', 'sldust00', 'sldlst00', 'vtdst00', 'zcta5ce00',
       'tazce00', 'ugace00', 'puma5ce00','vtdst10','tazce10','uace10','puma5ce10','tazce', 'uace', 'vtdst',  'zcta5ce10', 'puma5ce', 'ugace10','pumace10', 'estatefp', 'ugace', 'blockce', 'pumace20', 'sdadmlea', 'uace20', 'cnectafp', 'nctadvfp','nectafp']);
INSERT INTO loader_lookuptables(process_order, lookup_name, table_name, load, level_county, level_state, single_geom_mode, insert_mode, pre_load_process, post_load_process, columns_exclude )
VALUES(7, 'featnames', 'featnames', true, true, false,false, 'a',
'${psql} -c "CREATE TABLE ${data_schema}.${state_abbrev}_${table_name}(CONSTRAINT pk_${state_abbrev}_${table_name} PRIMARY KEY (gid)) INHERITS(tiger.${table_name});ALTER TABLE ${data_schema}.${state_abbrev}_${table_name} ALTER COLUMN statefp SET DEFAULT ''${state_fips}'';" ',
'${psql} -c "CREATE INDEX idx_${data_schema}_${state_abbrev}_${lookup_name}_snd_name ON ${data_schema}.${state_abbrev}_${table_name} USING btree (soundex(name));"
${psql} -c "CREATE INDEX idx_${data_schema}_${state_abbrev}_${lookup_name}_lname ON ${data_schema}.${state_abbrev}_${table_name} USING btree (lower(name));"
${psql} -c "CREATE INDEX idx_${data_schema}_${state_abbrev}_${lookup_name}_tlid_statefp ON ${data_schema}.${state_abbrev}_${table_name} USING btree (tlid,statefp);"
${psql} -c "ALTER TABLE ${data_schema}.${state_abbrev}_${lookup_name} ADD CONSTRAINT chk_statefp CHECK (statefp = ''${state_fips}'');"
${psql} -c "vacuum analyze ${data_schema}.${state_abbrev}_${lookup_name};"', ARRAY['gid','statefp', 'geoidfq']);

INSERT INTO loader_lookuptables(process_order, lookup_name, table_name, load, level_county, level_state, single_geom_mode, insert_mode, pre_load_process, post_load_process, columns_exclude )
VALUES(8, 'edges', 'edges', true, true, false,false, 'a',
'${psql} -c "CREATE TABLE ${data_schema}.${state_abbrev}_${table_name}(CONSTRAINT pk_${state_abbrev}_${table_name} PRIMARY KEY (gid)) INHERITS(tiger.${table_name});"',
'${psql} -c "ALTER TABLE ${data_schema}.${state_abbrev}_${table_name} ADD CONSTRAINT chk_statefp CHECK (statefp = ''${state_fips}'');"
${psql} -c "CREATE INDEX idx_${data_schema}_${state_abbrev}_${lookup_name}_tlid ON ${data_schema}.${state_abbrev}_${table_name} USING btree (tlid);"
${psql} -c "CREATE INDEX idx_${data_schema}_${state_abbrev}_${lookup_name}tfidr ON ${data_schema}.${state_abbrev}_${table_name} USING btree (tfidr);"
${psql} -c "CREATE INDEX idx_${data_schema}_${state_abbrev}_${lookup_name}_tfidl ON ${data_schema}.${state_abbrev}_${table_name} USING btree (tfidl);"
${psql} -c "CREATE INDEX idx_${data_schema}_${state_abbrev}_${lookup_name}_countyfp ON ${data_schema}.${state_abbrev}_${table_name} USING btree (countyfp);"
${psql} -c "CREATE INDEX ${data_schema}_${state_abbrev}_${table_name}_the_geom_gist ON ${data_schema}.${state_abbrev}_${table_name} USING gist(the_geom);"
${psql} -c "CREATE INDEX idx_${data_schema}_${state_abbrev}_${lookup_name}_zipl ON ${data_schema}.${state_abbrev}_${lookup_name} USING btree (zipl);"
${psql} -c "CREATE TABLE ${data_schema}.${state_abbrev}_zip_state_loc(CONSTRAINT pk_${state_abbrev}_zip_state_loc PRIMARY KEY(zip,stusps,place)) INHERITS(tiger.zip_state_loc);"
${psql} -c "INSERT INTO ${data_schema}.${state_abbrev}_zip_state_loc(zip,stusps,statefp,place) SELECT DISTINCT e.zipl, ''${state_abbrev}'', ''${state_fips}'', p.name FROM ${data_schema}.${state_abbrev}_edges AS e INNER JOIN ${data_schema}.${state_abbrev}_faces AS f ON (e.tfidl = f.tfid OR e.tfidr = f.tfid) INNER JOIN ${data_schema}.${state_abbrev}_place As p ON(f.statefp = p.statefp AND f.placefp = p.placefp ) WHERE e.zipl IS NOT NULL;"
${psql} -c "CREATE INDEX idx_${data_schema}_${state_abbrev}_zip_state_loc_place ON ${data_schema}.${state_abbrev}_zip_state_loc USING btree(soundex(place));"
${psql} -c "ALTER TABLE ${data_schema}.${state_abbrev}_zip_state_loc ADD CONSTRAINT chk_statefp CHECK (statefp = ''${state_fips}'');"
${psql} -c "vacuum analyze ${data_schema}.${state_abbrev}_${lookup_name};"
${psql} -c "vacuum analyze ${data_schema}.${state_abbrev}_zip_state_loc;"
${psql} -c "CREATE TABLE ${data_schema}.${state_abbrev}_zip_lookup_base(CONSTRAINT pk_${state_abbrev}_zip_state_loc_city PRIMARY KEY(zip,state, county, city, statefp)) INHERITS(tiger.zip_lookup_base);"
${psql} -c "INSERT INTO ${data_schema}.${state_abbrev}_zip_lookup_base(zip,state,county,city, statefp) SELECT DISTINCT e.zipl, ''${state_abbrev}'', c.name,p.name,''${state_fips}''  FROM ${data_schema}.${state_abbrev}_edges AS e INNER JOIN tiger.county As c  ON (e.countyfp = c.countyfp AND e.statefp = c.statefp AND e.statefp = ''${state_fips}'') INNER JOIN ${data_schema}.${state_abbrev}_faces AS f ON (e.tfidl = f.tfid OR e.tfidr = f.tfid) INNER JOIN ${data_schema}.${state_abbrev}_place As p ON(f.statefp = p.statefp AND f.placefp = p.placefp ) WHERE e.zipl IS NOT NULL;"
${psql} -c "ALTER TABLE ${data_schema}.${state_abbrev}_zip_lookup_base ADD CONSTRAINT chk_statefp CHECK (statefp = ''${state_fips}'');"
${psql} -c "CREATE INDEX idx_${data_schema}_${state_abbrev}_zip_lookup_base_citysnd ON ${data_schema}.${state_abbrev}_zip_lookup_base USING btree(soundex(city));"',  ARRAY['gid', 'geoid', 'geoidfq', 'divroad'] );

INSERT INTO loader_lookuptables(process_order, lookup_name, table_name, load, level_county, level_state, single_geom_mode, insert_mode, pre_load_process, post_load_process,columns_exclude )
VALUES(9, 'addr', 'addr', true, true, false,false, 'a',
	'${psql} -c "CREATE TABLE ${data_schema}.${state_abbrev}_${lookup_name}(CONSTRAINT pk_${state_abbrev}_${table_name} PRIMARY KEY (gid)) INHERITS(tiger.${table_name});ALTER TABLE ${data_schema}.${state_abbrev}_${lookup_name} ALTER COLUMN statefp SET DEFAULT ''${state_fips}'';" ',
	'${psql} -c "ALTER TABLE ${data_schema}.${state_abbrev}_${lookup_name} ADD CONSTRAINT chk_statefp CHECK (statefp = ''${state_fips}'');"
	${psql} -c "CREATE INDEX idx_${data_schema}_${state_abbrev}_${lookup_name}_least_address ON tiger_data.${state_abbrev}_addr USING btree (least_hn(fromhn,tohn) );"
	${psql} -c "CREATE INDEX idx_${data_schema}_${state_abbrev}_${table_name}_tlid_statefp ON ${data_schema}.${state_abbrev}_${table_name} USING btree (tlid, statefp);"
	${psql} -c "CREATE INDEX idx_${data_schema}_${state_abbrev}_${table_name}_zip ON ${data_schema}.${state_abbrev}_${table_name} USING btree (zip);"
	${psql} -c "CREATE TABLE ${data_schema}.${state_abbrev}_zip_state(CONSTRAINT pk_${state_abbrev}_zip_state PRIMARY KEY(zip,stusps)) INHERITS(tiger.zip_state); "
	${psql} -c "INSERT INTO ${data_schema}.${state_abbrev}_zip_state(zip,stusps,statefp) SELECT DISTINCT zip, ''${state_abbrev}'', ''${state_fips}'' FROM ${data_schema}.${state_abbrev}_${lookup_name} WHERE zip is not null;"
	${psql} -c "ALTER TABLE ${data_schema}.${state_abbrev}_zip_state ADD CONSTRAINT chk_statefp CHECK (statefp = ''${state_fips}'');"
	${psql} -c "vacuum analyze ${data_schema}.${state_abbrev}_${lookup_name};"',  ARRAY['gid','geoidfq', 'statefp','fromarmid', 'toarmid']);

INSERT INTO loader_lookuptables(process_order, lookup_name, table_name, load, level_county, level_state, single_geom_mode, insert_mode, pre_load_process, post_load_process,columns_exclude )
VALUES(9, 'addrfeat', 'addrfeat', false, true, false,true, 'a',
	'${psql} -c "CREATE TABLE ${data_schema}.${state_abbrev}_${lookup_name}(CONSTRAINT pk_${state_abbrev}_${table_name} PRIMARY KEY (gid)) INHERITS(tiger.${table_name});ALTER TABLE ${data_schema}.${state_abbrev}_${lookup_name} ALTER COLUMN statefp SET DEFAULT ''${state_fips}'';" ',
	'${psql} -c "ALTER TABLE ${data_schema}.${state_abbrev}_${lookup_name} ADD CONSTRAINT chk_statefp CHECK (statefp = ''${state_fips}'');"
	${psql} -c "vacuum analyze ${data_schema}.${state_abbrev}_${lookup_name};"',  ARRAY['gid','statefp','fromarmid', 'toarmid']);

CREATE OR REPLACE FUNCTION loader_generate_nation_script(os text)
  RETURNS SETOF text AS
$BODY$
WITH lu AS (SELECT lookup_name, table_name, pre_load_process,post_load_process, process_order, insert_mode, single_geom_mode, level_nation, level_county, level_state
    FROM  loader_lookuptables
				WHERE level_nation = true AND load = true)
SELECT
	loader_macro_replace(
		replace(
			loader_macro_replace(declare_sect
				, ARRAY['staging_fold', 'website_root', 'psql',  'data_schema', 'staging_schema'],
				ARRAY[variables.staging_fold, variables.website_root, platform.psql, variables.data_schema, variables.staging_schema]
			), '/', platform.path_sep) || '
'  ||
	-- Nation level files
	array_to_string( ARRAY(SELECT loader_macro_replace('cd ' || replace(variables.staging_fold,'/', platform.path_sep) || '
' || platform.wget || ' ' || variables.website_root  || '/'

-- hardcoding zcta5 path since doesn't follow convention
|| upper(CASE WHEN table_name = 'zcta510' THEN 'zcta5' ELSE table_name END)  || '/tl_' || variables.tiger_year || '_us_' || lower(table_name) || '.zip --mirror --reject=html
'
|| 'cd ' ||  replace(variables.staging_fold,'/', platform.path_sep) || '/' || replace(regexp_replace(variables.website_root, 'http[s]?://', ''),'ftp://','')  || '/'
-- note have to hard-code folder path for zcta because doesn't follow convention
|| upper(CASE WHEN table_name = 'zcta510' THEN 'zcta5' ELSE table_name END)  || '
' || replace(platform.unzip_command, '*.zip', 'tl_*' || table_name || '.zip ') || '
' || COALESCE(lu.pre_load_process || E'\n', '') || platform.loader || ' -D -' ||  lu.insert_mode || ' -s 4269 -g the_geom '
		|| CASE WHEN lu.single_geom_mode THEN ' -S ' ELSE ' ' END::text || ' -W "latin1" tl_' || variables.tiger_year
	|| '_us_' || lu.table_name || '.dbf tiger_staging.' || lu.table_name || ' | '::text || platform.psql
		|| COALESCE(E'\n' ||
			lu.post_load_process , '') , ARRAY['loader','table_name', 'lookup_name'], ARRAY[platform.loader, lu.table_name, lu.lookup_name ]
			)
				FROM lu
				ORDER BY process_order, lookup_name), E'\n') ::text
	, ARRAY['psql', 'data_schema','staging_schema', 'staging_fold', 'website_root'],
	ARRAY[platform.psql,  variables.data_schema, variables.staging_schema, variables.staging_fold, variables.website_root])
			AS shell_code
FROM tiger.loader_variables As variables
	 CROSS JOIN tiger.loader_platform As platform
WHERE platform.os = $1 -- generate script for selected platform
;
$BODY$
  LANGUAGE sql VOLATILE;

CREATE OR REPLACE FUNCTION loader_generate_script(param_states text[], os text)
  RETURNS SETOF text AS
$BODY$
SELECT
	loader_macro_replace(
		replace(
			loader_macro_replace(declare_sect
				, ARRAY['staging_fold', 'state_fold','website_root', 'psql', 'state_abbrev', 'data_schema', 'staging_schema', 'state_fips'],
				ARRAY[variables.staging_fold, s.state_fold, variables.website_root, platform.psql, s.state_abbrev, variables.data_schema, variables.staging_schema, s.state_fips::text]
			), '/', platform.path_sep) || '
' ||
	-- State level files - if an override website is specified we use that instead of variable one
	array_to_string( ARRAY(SELECT 'cd ' || replace(variables.staging_fold,'/', platform.path_sep) || '
' || platform.wget || ' ' || COALESCE(lu.website_root_override,variables.website_root || '/' || upper(lookup_name)  ) || '/tl_' || variables.tiger_year || '_' || s.state_fips || '_' || lower(table_name) || '.zip --mirror --reject=html
'
|| 'cd ' ||  replace(variables.staging_fold,'/', platform.path_sep) || '/' || replace(regexp_replace(COALESCE(lu.website_root_override, variables.website_root || '/' || upper(lookup_name) ), 'http[s]?://', ''),'ftp://','')    || '
' || replace(platform.unzip_command, '*.zip', 'tl_' || variables.tiger_year || '_' || s.state_fips || '*_' || table_name || '.zip ') || '
' ||loader_macro_replace(COALESCE(lu.pre_load_process || E'\n', '') || platform.loader || ' -D -' ||  lu.insert_mode || ' -s 4269 -g the_geom '
		|| CASE WHEN lu.single_geom_mode THEN ' -S ' ELSE ' ' END::text || ' -W "latin1" tl_' || variables.tiger_year || '_' || s.state_fips
	|| '_' || lu.table_name || '.dbf tiger_staging.' || lower(s.state_abbrev) || '_' || lu.table_name || ' | '::text || platform.psql
		|| COALESCE(E'\n' ||
			lu.post_load_process , '') , ARRAY['loader','table_name', 'lookup_name'], ARRAY[platform.loader, lu.table_name, lu.lookup_name ])
				FROM tiger.loader_lookuptables AS lu
				WHERE level_state = true AND load = true
				ORDER BY process_order, lookup_name), E'\n') ::text
	-- County Level files
	|| E'\n' ||
		array_to_string( ARRAY(SELECT 'cd ' || replace(variables.staging_fold,'/', platform.path_sep) || '
' ||
-- explode county files create wget call for each county file
array_to_string (ARRAY(SELECT platform.wget || ' --mirror  ' || COALESCE(lu.website_root_override, variables.website_root || '/' || upper(lookup_name)  ) || '/tl_' || variables.tiger_year || '_' || s.state_fips || c.countyfp || '_' || lower(table_name) || '.zip ' || E'\n'  AS county_out
FROM tiger.county As c
WHERE c.statefp = s.state_fips), ' ')
|| 'cd ' ||  replace(variables.staging_fold,'/', platform.path_sep) || '/' || replace(regexp_replace(COALESCE(lu.website_root_override,variables.website_root || '/' || upper(lookup_name)  || '/'), 'http[s]?://', ''),'ftp://','')  || '
' || replace(platform.unzip_command, '*.zip', 'tl_*_' || s.state_fips || '*_' || table_name || '*.zip ') || '
' || loader_macro_replace(COALESCE(lu.pre_load_process || E'\n', '') || COALESCE(county_process_command || E'\n','')
				|| COALESCE(E'\n' ||lu.post_load_process , '') , ARRAY['loader','table_name','lookup_name'], ARRAY[platform.loader  || ' -D ' || CASE WHEN lu.single_geom_mode THEN ' -S' ELSE ' ' END::text, lu.table_name, lu.lookup_name ])
				FROM tiger.loader_lookuptables AS lu
				WHERE level_county = true AND load = true
				ORDER BY process_order, lookup_name), E'\n') ::text
	, ARRAY['psql', 'data_schema','staging_schema', 'staging_fold', 'state_fold', 'website_root', 'state_abbrev','state_fips'],
	ARRAY[platform.psql,  variables.data_schema, variables.staging_schema, variables.staging_fold, s.state_fold,variables.website_root, s.state_abbrev, s.state_fips::text])
			AS shell_code
FROM loader_variables As variables
		CROSS JOIN (SELECT name As state, abbrev As state_abbrev, lpad(st_code::text,2,'0') As state_fips,
			 lpad(st_code::text,2,'0') || '_'
	|| replace(name, ' ', '_') As state_fold
FROM tiger.state_lookup) As s CROSS JOIN tiger.loader_platform As platform
WHERE $1 @> ARRAY[state_abbrev::text]      -- If state is contained in list of states input generate script for it
AND platform.os = $2  -- generate script for selected platform
;
$BODY$
  LANGUAGE sql VOLATILE;

CREATE OR REPLACE FUNCTION loader_load_staged_data(param_staging_table text, param_target_table text, param_columns_exclude text[]) RETURNS integer
AS
$$
DECLARE
	var_sql text;
	var_staging_schema text; var_data_schema text;
	var_temp text;
	var_num_records bigint;
BEGIN
-- Add all the fields except geoid and gid
-- Assume all the columns are in same order as target
	SELECT staging_schema, data_schema INTO var_staging_schema, var_data_schema FROM loader_variables;
	var_sql := 'INSERT INTO ' || var_data_schema || '.' || quote_ident(param_target_table) || '(' ||
			array_to_string(ARRAY(SELECT quote_ident(column_name::text)
				FROM information_schema.columns
				 WHERE table_name = param_target_table
					AND table_schema = var_data_schema
					AND column_name <> ALL(param_columns_exclude)
                    ORDER BY column_name ), ',') || ') SELECT '
					|| array_to_string(ARRAY(SELECT quote_ident(column_name::text)
				FROM information_schema.columns
				 WHERE table_name = param_staging_table
					AND table_schema = var_staging_schema
					AND column_name <> ALL( param_columns_exclude)
                    ORDER BY column_name ), ',') ||' FROM '
					|| var_staging_schema || '.' || param_staging_table || ';';
	RAISE NOTICE '%', var_sql;
	EXECUTE (var_sql);
	GET DIAGNOSTICS var_num_records = ROW_COUNT;
	SELECT DropGeometryTable(var_staging_schema,param_staging_table) INTO var_temp;
	RETURN var_num_records;
END;
$$
LANGUAGE 'plpgsql' VOLATILE;

CREATE OR REPLACE FUNCTION loader_load_staged_data(param_staging_table text, param_target_table text)
RETURNS integer AS
$$
-- exclude this set list of columns if no exclusion list is specified

   SELECT  tiger.loader_load_staged_data($1, $2,(SELECT COALESCE(columns_exclude,ARRAY['gid', 'geoid',  'geoidfq20', 'cpi','suffix1ce', 'statefp00', 'statefp10', 'countyfp00','countyfp10'
   ,'tractce00','tractce10', 'blkgrpce00', 'blkgrpce10', 'blockce00', 'blockce10'
      , 'cousubfp00', 'submcdfp00', 'conctyfp00', 'placefp00', 'aiannhfp00', 'aiannhce00'
      , 'comptyp00', 'trsubfp00', 'trsubce00', 'anrcfp00', 'elsdlea00', 'scsdlea00',
       'unsdlea00', 'uace00', 'cd108fp', 'sldust00', 'sldlst00', 'vtdst00', 'zcta5ce00',
       'tazce00', 'ugace00', 'puma5ce00','vtdst10','tazce10','uace10','puma5ce10','tazce', 'uace', 'vtdst', 'zcta5ce', 'zcta5ce10', 'puma5ce', 'ugace10','pumace10', 'estatefp', 'ugace', 'blockce', 'cnectafp', 'geoidfq', 'nctadvfp', 'nectafp','pcinecta' ]) FROM loader_lookuptables WHERE $2 LIKE '%' || lookup_name))
$$
language 'sql' VOLATILE;

CREATE OR REPLACE FUNCTION loader_generate_census_script(param_states text[], os text)
  RETURNS SETOF text AS
$$
SELECT create_census_base_tables();
SELECT
	loader_macro_replace(
		replace(
			loader_macro_replace(declare_sect
				, ARRAY['staging_fold', 'state_fold','website_root', 'psql', 'state_abbrev', 'data_schema', 'staging_schema', 'state_fips'],
				ARRAY[variables.staging_fold, s.state_fold, variables.website_root, platform.psql, s.state_abbrev, variables.data_schema, variables.staging_schema, s.state_fips::text]
			), '/', platform.path_sep) || '
' ||
	-- State level files - if an override website is specified we use that instead of variable one
	array_to_string( ARRAY(SELECT 'cd ' || replace(variables.staging_fold,'/', platform.path_sep) || '
' || platform.wget || ' ' || COALESCE(lu.website_root_override,variables.website_root || '/' || upper(lookup_name)  ) || '/tl_' || variables.tiger_year || '_' || s.state_fips || '_' || lower(table_name) || '.zip --mirror --reject=html
'
|| 'cd ' ||  replace(variables.staging_fold,'/', platform.path_sep) || '/' || replace(regexp_replace(COALESCE(lu.website_root_override,variables.website_root || '/' || upper(lookup_name) ), 'http[s]+://', ''),'ftp://','')    || '
' || replace(platform.unzip_command, '*.zip', 'tl_' || variables.tiger_year || '_' || s.state_fips || '*_' || table_name || '.zip ') || '
' ||loader_macro_replace(COALESCE(lu.pre_load_process || E'\n', '') || platform.loader || ' -D -' ||  lu.insert_mode || ' -s 4269 -g the_geom '
		|| CASE WHEN lu.single_geom_mode THEN ' -S ' ELSE ' ' END::text || ' -W "latin1" tl_' || variables.tiger_year || '_' || s.state_fips
	|| '_' || lu.table_name || '.dbf tiger_staging.' || lower(s.state_abbrev) || '_' || lu.table_name || ' | '::text || platform.psql
		|| COALESCE(E'\n' ||
			lu.post_load_process , '') , ARRAY['loader','table_name', 'lookup_name'], ARRAY[platform.loader, lu.table_name, lu.lookup_name ])
				FROM loader_lookuptables AS lu
				WHERE level_state = true AND lu.lookup_name IN('bg','tract', 'tabblock')
				ORDER BY process_order, lookup_name), E'\n') ::text
	-- County Level files
	|| E'\n' ||
		array_to_string( ARRAY(SELECT 'cd ' || replace(variables.staging_fold,'/', platform.path_sep) || '
' ||
-- explode county files create wget call for each county file
array_to_string (ARRAY(SELECT platform.wget || ' --mirror  ' || COALESCE(lu.website_root_override,variables.website_root || '/' || upper(lookup_name)  ) || '/tl_' || variables.tiger_year || '_' || s.state_fips || c.countyfp || '_' || lower(table_name) || '.zip ' || E'\n'  AS county_out
FROM tiger.county As c
WHERE c.statefp = s.state_fips), ' ')
|| 'cd ' ||  replace(variables.staging_fold,'/', platform.path_sep) || '/' || replace(regexp_replace(COALESCE(lu.website_root_override,variables.website_root || '/' || upper(lookup_name)  || '/'), 'http[s]+://', ''),'ftp://','')  || '
' || replace(platform.unzip_command, '*.zip', 'tl_*_' || s.state_fips || '*_' || table_name || '*.zip ') || '
' || loader_macro_replace(COALESCE(lu.pre_load_process || E'\n', '') || COALESCE(county_process_command || E'\n','')
				|| COALESCE(E'\n' ||lu.post_load_process , '') , ARRAY['loader','table_name','lookup_name'], ARRAY[platform.loader  || ' -D ' || CASE WHEN lu.single_geom_mode THEN ' -S' ELSE ' ' END::text, lu.table_name, lu.lookup_name ])
				FROM loader_lookuptables AS lu
				WHERE level_county = true AND lu.lookup_name IN('bg','tract', 'tabblock')
				ORDER BY process_order, lookup_name), E'\n') ::text
	, ARRAY['psql', 'data_schema','staging_schema', 'staging_fold', 'state_fold', 'website_root', 'state_abbrev','state_fips'],
	ARRAY[platform.psql,  variables.data_schema, variables.staging_schema, variables.staging_fold, s.state_fold,variables.website_root, s.state_abbrev, s.state_fips::text])
			AS shell_code
FROM loader_variables As variables
		CROSS JOIN (SELECT name As state, abbrev As state_abbrev, lpad(st_code::text,2,'0') As state_fips,
			 lpad(st_code::text,2,'0') || '_'
	|| replace(name, ' ', '_') As state_fold
FROM state_lookup) As s CROSS JOIN loader_platform As platform
WHERE $1 @> ARRAY[state_abbrev::text]      -- If state is contained in list of states input generate script for it
AND platform.os = $2  -- generate script for selected platform
;
$$
  LANGUAGE sql VOLATILE;

SELECT create_census_base_tables();
COMMIT;
