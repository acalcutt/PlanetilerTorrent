#!/bin/bash

# Requires qbittorrent-cli https://github.com/fedarovich/qbittorrent-cli/wiki/Setup-Linux

hash="$1"

qbt torrent delete --with-files --url http://127.0.0.1:8080/ --username example --password example $hash