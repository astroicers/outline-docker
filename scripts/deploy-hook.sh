#!/bin/sh
# Send SIGHUP to nginx container via Docker socket to trigger cert reload
curl -s --unix-socket /var/run/docker.sock \
  -X POST "http://localhost/containers/outline-docker-nginx-1/kill?signal=HUP"
echo "Sent HUP to nginx"
