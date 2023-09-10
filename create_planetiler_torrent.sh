#!/bin/bash

# Exit on error
set -e

year="$(date +'%Y')"
date="$(date +'%Y%m%d')"

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

# Change to working directory
cd /store/planetilerdump

# Make directory to put outpul files
mkdir -p $year

# Cleanup
rm -rf data

# Run the dump
time java -Xmx25g \
  -jar /opt/planetiler/planetiler_0.6.0.jar \
  `# Download the latest planet.osm.pbf from s3://osm-pds bucket` \
  --area=planet --bounds=planet --download \
  `# Accelerate the download by fetching the 10 1GB chunks at a time in parallel` \
  --download-threads=10 --download-chunk-size-mb=1000 \
  `# Also download name translations from wikidata` \
  --fetch-wikidata \
  --output=planetiler-$date.mbtiles \
  `# Store temporary node locations at fixed positions in a memory-mapped file` \
  --nodemap-type=array --storage=mmap

# Function to create bittorrent files
function mk_torrent {
  type="$1"
  format="$2"
  dir="$3"
  s_year="$4"
  web_dir="${dir}${s_year}"
  name="${type}-${date}.${format}"
  web_path="${web_dir}/${name}"
  rss_web_dir="https://planetiler.techidiots.net/${dir}"
  rss_file="${type}-${format}-rss.xml"
  torrent_file="${name}.torrent"
  torrent_url="${rss_web_dir}${s_year}/${torrent_file}"

  # create .torrent file
  mktorrent -l 22 "${name}" \
     -a udp://tracker.opentrackr.org:1337 \
     -a udp://tracker.datacenterlight.ch:6969/announce,http://tracker.datacenterlight.ch:6969/announce \
     -a udp://tracker.torrent.eu.org:451 \
     -a udp://tracker-udp.gbitt.info:80/announce,http://tracker.gbitt.info/announce,https://tracker.gbitt.info/announce \
     -a http://retracker.local/announce \
     -w "https://planetiler.techidiots.net/${web_path}" \
     -c "Planetiler ${type} data export ${name}" \
     -o "${torrent_file}" > /dev/null

  # create .xml global RSS headers if missing
  torrent_time_rfc="$(date -R -r ${torrent_file})"
  test -f "${rss_file}" || echo "<x/>" | xmlstarlet select --xml-decl --indent \
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
	--elem "title" --output "Planetiler ${type} ${format} torrent RSS" --break \
	--elem "link"  --output "${rss_web_dir}" --break \
	--elem "atom:link" \
		--attr "href" --output "${rss_web_dir}/${rss_file}" --break \
		--attr "rel" --output "self" --break \
		--attr "type" --output "application/rss+xml" --break \
		--break \
	--elem "description" --output "${type}.${format}.torrent RSS feed" --break \
	--elem "copyright" --output "Source: OpenStreetMap contributors, under ODbL 1.0 licence. OpenMapTiles under BSD 3-Clause License/CC-BY 4.0" --break \
	--elem "generator" --output "planetiler shell script v1.0" --break \
	--elem "language" --output "en" --break \
	--elem "lastBuildDate" --output "${torrent_time_rfc}" \
	> "${rss_file}"

  # add newly created .torrent file as new entry to .xml RSS feed, removing excess entries
  torrent_size="$(stat --format="%s" ${torrent_file})"
  xmlstarlet edit --inplace \
	-a "//lastBuildDate" -t elem -n item -v ""  \
	-s "//item[1]" -t elem -n "title" -v "${torrent_file}" \
	-s "//item[1]" -t elem -n "guid" -v "${torrent_url}" \
	-s "//item[1]" -t elem -n "link" -v "${torrent_url}" \
	-s "//item[1]" -t elem -n "pubDate" -v "${torrent_time_rfc}" \
	-s "//item[1]" -t elem -n "category" -v "Planetiler data" \
	-s "//item[1]" -t elem -n "enclosure" \
		-s "//item[1]"/enclosure -t attr -n "type" -v "application/x-bittorrent" \
		-s "//item[1]"/enclosure -t attr -n "length" -v "${torrent_size}" \
		-s "//item[1]"/enclosure -t attr -n "url" -v "${torrent_url}" \
	-s "//item[1]" -t elem -n "description" -v "Planetiler torrent ${torrent_file}" \
	-u /rss/channel/lastBuildDate -v "${torrent_time_rfc}" \
	-d /rss/@atom:DUMMY \
	-d "//item[position()>5]" \
	"${rss_file}"
}

# Function to install a dump in place
function install_dump {
  type="$1"
  format="$2"
  dir="$3"
  year="$4"
  name="${type}-${date}.${format}"
  latest="${type}-latest.${format}"
  rss_file="${type}-${format}-rss.xml"

  md5sum "${name}" > "${name}.md5"
  mkdir -p "${dir}/${year}"
  mv "${name}" "${name}.md5" "${dir}/${year}"
  ln -sf "${year:-.}/${name}" "${dir}/${latest}"
  test -f "${name}.torrent" && mv "${name}.torrent" "${dir}/${year}" && ln -sf "${year:-.}/${name}.torrent" "${dir}/${latest}.torrent"
  test -f "${rss_file}" && xmllint --noout "${rss_file}" && cp -f "${rss_file}" "${dir}"
  rm -f "${dir}/${latest}.md5"
  sed -e "s/${name}/${latest}/" "${dir}/${year}/${name}.md5" > "${dir}/${latest}.md5"
}

# Create *.torrent files

mk_torrent "planetiler" "mbtiles" "planetiler" "${year}"

# Move dumps into place
install_dump "planetiler" "mbtiles" "/store/http/" "${year}"

# Remove pbf dumps older than 90 days
find /store/http/ \
     -maxdepth 1 -mindepth 1 -type f -mtime +90 \
     \( \
     -iname 'planetiler-*.mbtiles' \
     -o -iname 'planetiler-*.mbtiles.md5' \
     -o -iname 'planetiler-*.pmtiles' \
     -o -iname 'planetiler-*.pmtiles.md5' \
     \) \
     -delete
