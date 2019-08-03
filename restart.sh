#!/bin/bash
docker rm -f $(docker ps -aq --filter="name=${PWD##*/}")
#sudo rm -rf var
export IOTSR_DEVICE_ID=$(hostname)
docker-compose up -d --build