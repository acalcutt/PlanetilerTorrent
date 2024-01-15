#!/bin/bash

# Exit on error
set -e

date=`date +%Y%m%d`
protomaps_dir="/mnt/usb/protomaps" #directory that the protomaps
http_dir="/store/http" #directory where the torrent files and rss files get created
torrent_autoupload_dir="/store/upload_protomaps" #directory where a copy of the torrent file gets placed to start autouploading in qbittorent
remote_file="https://build.protomaps.com/${date}.pmtiles" #remote url for the protomaps file
local_file="${protomaps_dir}/planetiler-protomaps-${date}.pmtiles" #local filename and path for the local protomaps file
latest_file="${protomaps_dir}/planetiler-protomaps-latest.pmtiles" #local symbolic link to the latest file

# Function to create bittorrent files
function mk_torrent {
  type="$1"
  format="$2"
  infile="$3"
  http_dir="$4"
  upload_dir="$5"
  copyright="$6"
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
	 -w "${remote_file}" \
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

if ! [ -f ${local_file} ]; then
  if wget -q --method=HEAD "${remote_file}"; then
     echo "${local_file} does not exists, downloading"
     if wget -O ${local_file} "${remote_file}";then
         echo "${local_file} downloaded, creating symbolic link and torrent"
         ln -sfn ${local_file} ${latest_file}
         mk_torrent "planetiler-protomaps" "pmtiles" ${local_file} ${http_dir} ${torrent_autoupload_dir} "OpenStreetMap contributors, under ODbL 1.0 licence. Protomaps under Creative Commons Zero (CC0) license"
     else
       echo "error downloading ${remote_file}"
     fi
  else
    echo "${remote_file} not found"
  fi
else
  echo "${local_file} already exists, exiting"
fi
