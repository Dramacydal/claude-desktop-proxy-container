#!/bin/bash
docker build --network=host -t claude-desktop-proxy-container \
    --build-arg PUID=$(id -u) --build-arg PGID=$(id -g) .
