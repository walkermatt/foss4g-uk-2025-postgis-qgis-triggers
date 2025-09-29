echo -n "Password: "
read -s PGPASSWORD

export PGUSER=postgres
export PGPASSWORD=$PGPASSWORD
export PGHOST=localhost
export PGPORT=5432

psql -f setup.sql
raster2pgsql -s 27700 -t 512x512 -l 2,4 -q -c -I -C -M ~/Downloads/os_miniscale/MiniScale_standard_R26.tif "uk"."os_miniscale" | psql -d gis
