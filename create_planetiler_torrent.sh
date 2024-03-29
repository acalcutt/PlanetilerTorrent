#!/bin/bash

# Exit on error
set -e

planetiler_protomaps_path="/opt/protomaps/tiles/target/protomaps-basemap-HEAD-with-deps.jar" #path to planetiler with protomaps profile support.
planetiler_openmaptiles_path="/opt/planetiler/planetiler_0.6.0.jar" #path to planetiler with openmaptiles profile support.
working_dir="/store/planetiler" #directory where temp files get created.
outfile_dir="/mnt/usb" #directory that panetiler will output the pmtiles/mbtiles files it creates
http_dir="/store/http" #directory where the torrent files and rss files get created
torrent_autoupload_dir="/store/upload_usb" #directory where a copy of the torrent file gets placed to start autouploading in qbittorent

# Get the name of the file and the expected pattern
file_name="$1"
file_path="$2"
file_hash="$3"
pattern="^planet-([0-9]{6})\.osm.pbf$"

# Give up now if the file isn't a database dump
[[ $file_name =~ $pattern ]] || exit 0

year="$(date +'%Y')"
date="${BASH_REMATCH[1]}"

# Check the lock
if [ -f /tmp/planetilerdump.lock ]; then
    if [ "$(ps -p `cat /tmp/planetilerdump.lock` | wc -l)" -gt 1 ]; then
        echo "Error: Another planetilerdump is running"
        exit 1
    else
        rm /tmp/planetilerdump.lock
    fi
fi

# Redirect this shell's output to a file. This is so that it
# can be emailed later, since this script is run from incron
# and incron doesn't yet support MAILTO like cron does. The
# command below appears to work in bash as well as dash.
logfile="/tmp/planetilerdump.log.$$"
exec > "${logfile}" 2>&1

# Create lock file
echo $$ > /tmp/planetilerdump.lock

# Define cleanup function
function cleanup {
    # Remove the lock file
    rm /tmp/planetilerdump.lock

    # Send an email with the output, since incron doesn't yet
    # support doing this in the incrontab
    if [[ -s "$logfile" ]]
    then
        mailx -s "Planetiler output: ${file}" acalcutt@techidiots.net < "${logfile}"
    fi

    # Remove the log file
    rm -f "${logfile}"
}

# Remove lock on exit
trap cleanup EXIT

function mk_openmaptiles {
  type="$1"
  format="$2"
  osm_path="$3"
  dest="$4"
  outfile="${dest}/${type}-${date}.${format}"
  latestfile="${dest}/${type}-latest.${format}"

  echo "Starting ${type} ${format} export"
  time java -Xmx32g \
    -jar ${planetiler_openmaptiles_path} \
    --area=planet --bounds=planet --download --osm-path=${osm_path} \
    --download-threads=10 --download-chunk-size-mb=1000 \
    --fetch-wikidata \
    --output=${outfile} \
    --nodemap-type=array --storage=mmap

  if [ -f "${outfile}" ]; then
    ln -sfn ${outfile} ${latestfile}
  fi

}

function mk_protomaps {
  type="$1"
  format="$2"
  osm_path="$3"
  dest="$4"
  outfile="${dest}/${type}-${date}.${format}"
  latestfile="${dest}/${type}-latest.${format}"

  echo "Starting ${type} ${format} export"
  time java -Xmx32g \
    -jar ${planetiler_protomaps_path} \
    --area=planet --bounds=planet --download --osm-path=${osm_path} \
    --download-threads=10 --download-chunk-size-mb=1000 \
    --fetch-wikidata \
    --output=${outfile} \
    --nodemap-type=array --storage=mmap

  if [ -f "${outfile}" ]; then
    ln -sfn ${outfile} ${latestfile}
  fi

}


# Function to create bittorrent files
function mk_torrent {
  type="$1"
  format="$2"
  source_dir="$3"
  http_dir="$4"
  upload_dir="$5"
  copyright="$6"
  infile="${source_dir}/${type}-${date}.${format}"
  http_web_dir="https://planetgen.wifidb.net"
  name="${type}-${date}.${format}"
  rss_name="rss-${type}-${format}.xml"
  rss_path="${http_dir}/${rss_name}"
  torrent_name="${name}.torrent"
  torrent_dir="${http_dir}/${type}/${format}"
  torrent_path="${torrent_dir}/${torrent_name}"
  torrent_url="${http_web_dir}/${type}/${format}/${torrent_name}"

  # create .torrent file
  echo "Creating Torrent $torrent_name from $infile"
  mkdir -p ${torrent_dir}
  mktorrent -l 24 "${infile}" \
     -a udp://tracker.opentrackr.org:1337 \
     -a udp://tracker.datacenterlight.ch:6969/announce,http://tracker.datacenterlight.ch:6969/announce \
     -a udp://tracker.torrent.eu.org:451 \
     -a udp://tracker-udp.gbitt.info:80/announce,http://tracker.gbitt.info/announce,https://tracker.gbitt.info/announce \
     -a http://retracker.local/announce \
     -c "Planetiler ${type} data export ${name}" \
     -o "${torrent_path}" > /dev/null

  if [ -f "$torrent_path" ]; then
    # create md5 of original file
    echo "Creating MD5 of $infile"
    md5_path="${torrent_dir}/${name}.md5"
    md5sum "${infile}" | cut -f 1 -d " " > ${md5_path}

    # copy torrent to qbittorent upload dir
    autoseed_path="${upload_dir}/${torrent_name}"
    cp ${torrent_path} ${autoseed_path}

    # create latest symbolic link
    latest_path="${torrent_dir}/${type}-latest.${format}.torrent"
    latest_md5="${torrent_dir}/${type}-latest.${format}.md5"
    ln -sfn ${torrent_path} ${latest_path}
    ln -sfn ${md5_path} ${latest_md5}

    # create .xml global RSS headers if missing
    echo "Creating RSS $rss_name"
    torrent_time_rfc="$(date -R -r ${torrent_path})"
    test -f "${rss_path}" || echo "<x/>" | xmlstarlet select --xml-decl --indent \
    -N "atom=http://www.w3.org/2005/Atom" \
    -N "dcterms=http://purl.org/dc/terms/" \
    -N "content=http://purl.org/rss/1.0/modules/content/" \
    --encode "UTF-8" \
    --template \
    --match / \
    --elem "rss" \
        --attr "version" --output "2.0" --break \
        --attr "atom:DUMMY" --break \
    --elem "channel" \
    --elem "title" --output "${type} ${format} torrent RSS" --break \
    --elem "link"  --output "${http_web_dir}" --break \
    --elem "atom:link" \
        --attr "href" --output "${http_web_dir}/${rss_name}" --break \
        --attr "rel" --output "self" --break \
        --attr "type" --output "application/rss+xml" --break \
        --break \
    --elem "description" --output "${type} ${format} torrent RSS feed" --break \
    --elem "copyright" --output "${copyright}" --break \
    --elem "generator" --output "planetgen.wifidb.net shell script v1.0" --break \
    --elem "language" --output "en" --break \
    --elem "lastBuildDate" --output "${torrent_time_rfc}" \
    > "${rss_path}"

    # add newly created .torrent file as new entry to .xml RSS feed, removing excess entries
    torrent_size="$(stat --format="%s" ${torrent_path})"
    xmlstarlet edit --inplace \
    -a "//lastBuildDate" -t elem -n item -v ""  \
    -s "//item[1]" -t elem -n "title" -v "${torrent_name}" \
    -s "//item[1]" -t elem -n "guid" -v "${torrent_url}" \
    -s "//item[1]" -t elem -n "link" -v "${torrent_url}" \
    -s "//item[1]" -t elem -n "pubDate" -v "${torrent_time_rfc}" \
    -s "//item[1]" -t elem -n "category" -v "Planetiler data" \
    -s "//item[1]" -t elem -n "enclosure" \
        -s "//item[1]"/enclosure -t attr -n "type" -v "application/x-bittorrent" \
        -s "//item[1]"/enclosure -t attr -n "length" -v "${torrent_size}" \
        -s "//item[1]"/enclosure -t attr -n "url" -v "${torrent_url}" \
    -s "//item[1]" -t elem -n "description" -v "${type} ${format} torrent ${date}" \
    -u /rss/channel/lastBuildDate -v "${torrent_time_rfc}" \
    -d /rss/@atom:DUMMY \
    -d "//item[position()>1]" \
    "${rss_path}"
  fi
  

}

echo "Download File: $file_name $file_path $file_hash"

# Change to working directory
cd ${working_dir}

# Cleanup
rm -rf data

# Create openmaptiles pmtiles export and torrent
mk_openmaptiles "planetiler-openmaptiles" "pmtiles" ${file_path} ${outfile_dir}
mk_torrent "planetiler-openmaptiles" "pmtiles" ${outfile_dir} ${http_dir} ${torrent_autoupload_dir} "OpenStreetMap contributors, under ODbL 1.0 licence. OpenMapTiles under BSD 3-Clause License/CC-BY 4.0"

# Create openmaptiles mbtiles export and torrent
mk_openmaptiles "planetiler-openmaptiles" "mbtiles" ${file_path} ${outfile_dir}
mk_torrent "planetiler-openmaptiles" "mbtiles" ${outfile_dir} ${http_dir} ${torrent_autoupload_dir} "OpenStreetMap contributors, under ODbL 1.0 licence. OpenMapTiles under BSD 3-Clause License/CC-BY 4.0"

# Create protomaps pmtiles export and torrent
mk_protomaps "planetiler-protomaps" "pmtiles" ${file_path} ${outfile_dir}
mk_torrent "planetiler-protomaps" "pmtiles" ${outfile_dir} ${http_dir} ${torrent_autoupload_dir} "OpenStreetMap contributors, under ODbL 1.0 licence. Protomaps under Creative Commons Zero (CC0) license"

# Create protomaps mbtiles export and torrent
mk_protomaps "planetiler-protomaps" "mbtiles" ${file_path} ${outfile_dir}
mk_torrent "planetiler-protomaps" "mbtiles" ${outfile_dir} ${http_dir} ${torrent_autoupload_dir} "OpenStreetMap contributors, under ODbL 1.0 licence. Protomaps under Creative Commons Zero (CC0) license"

# Remove torrent files older than 35 days
find ${http_dir} \
     -maxdepth 4 -mindepth 1 -type f -mtime +15 \
     \( \
     -iname 'planetiler-*.mbtiles.md5' \
     -o -iname 'planetiler-*.mbtiles.torrent' \
     -o -iname 'planetiler-*.pmtiles.md5' \
     -o -iname 'planetiler-*.pmtiles.torrent' \
     \) \
     -delete

# Remove export files older than 35 days
find ${outfile_dir} \
     -maxdepth 4 -mindepth 1 -type f -mtime +15 \
     \( \
     -iname 'planetiler-*.mbtiles' \
     -o -iname 'planetiler-*.pmtiles' \
     \) \
     -delete

#cleanup planet torrent
/opt/create_planet/cleanup_torrent.sh $file_hash
