#!/bin/bash

# Exit on error
set -e

# Get the name of the file and the expected pattern
file_name="$1"
file_path="$2"
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

function mk_planetiler {
  type="$1"
  format="$2"
  osm_path="$3"

  echo "Starting ${type} ${format} export"
  time java -Xmx25g \
    -jar /opt/planetiler/planetiler_0.6.0.jar \
    --area=planet --bounds=planet --download --osm-path=${osm_path} \
    --download-threads=10 --download-chunk-size-mb=1000 \
    --fetch-wikidata \
    --output=${type}-${date}.${format} \
    --nodemap-type=array --storage=mmap
}

# Function to create bittorrent files
function mk_torrent {
  type="$1"
  format="$2"
  http_dir="$3"
  upload_dir="$4"
  http_web_dir="https://planetgen.wifidb.net"
  name="${type}-${date}.${format}"
  rss_name="${type}-${format}-rss.xml"
  rss_path="${http_dir}/${rss_name}"
  torrent_name="${name}.torrent"
  torrent_dir="${http_dir}/${type}/${format}"
  torrent_path="${torrent_dir}/${torrent_name}"
  torrent_url="${http_web_dir}/${type}/${format}/${torrent_name}"
  latest_path="${torrent_dir}/${type}-latest.${format}.torrent"
  upload_path="${upload_dir}/${torrent_name}"

  # create .torrent file
  echo "Creating Torrent $torrent_name"
  mkdir -p $torrent_dir
  mktorrent -l 24 "${name}" \
     -a udp://tracker.opentrackr.org:1337 \
     -a udp://tracker.datacenterlight.ch:6969/announce,http://tracker.datacenterlight.ch:6969/announce \
     -a udp://tracker.torrent.eu.org:451 \
     -a udp://tracker-udp.gbitt.info:80/announce,http://tracker.gbitt.info/announce,https://tracker.gbitt.info/announce \
     -a http://retracker.local/announce \
     -c "Planetiler ${type} data export ${name}" \
     -o "${torrent_path}" > /dev/null

  if [ -f "$torrent_path" ]; then
    # create md5 of original file
	echo "Creating MD5 of $name"
    md5sum "${name}" > "${torrent_dir}/${name}.md5"

    # copy torrent to qbittorent upload dir
    cp $torrent_path $upload_path

    # create latest symbolic link
    ln -sfn $torrent_path $latest_path

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
    --elem "copyright" --output "OpenStreetMap contributors, under ODbL 1.0 licence. OpenMapTiles under BSD 3-Clause License/CC-BY 4.0" --break \
    --elem "generator" --output "wifidb.net planetiler shell script v1.0" --break \
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
    -d "//item[position()>5]" \
    "${rss_path}"
  fi
  

}

echo "Download File: $file_name - $file_path"

# Change to working directory
cd /store/planetiler

# Cleanup
rm -rf data

# Create mbtiles export and torrent
mk_planetiler "planetiler" "mbtiles" ${file_path}
mk_torrent "planetiler" "mbtiles" "/store/http" "/store/upload"

# Create p,tiles export and torrent
mk_planetiler "planetiler" "pmtiles" ${file_path}
mk_torrent "planetiler" "pmtiles" "/store/http" "/store/upload"

# Remove exports older than 15 days
find /store/ \
     -maxdepth 4 -mindepth 1 -type f -mtime +15 \
     \( \
     -iname 'planetiler-*.mbtiles' \
     -o -iname 'planetiler-*.mbtiles.md5' \
     -o -iname 'planetiler-*.mbtiles.torrent' \
     -o -iname 'planetiler-*.pmtiles' \
     -o -iname 'planetiler-*.pmtiles.md5' \
     -o -iname 'planetiler-*.pmtiles.torrent' \
     \) \
     -delete
