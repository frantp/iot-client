#!/bin/bash

export HOME="/root"
host="$(hostname)"
sreader "$@" | while IFS= read -r line; do
    IFS=' ' read -ra frags <<< "${line}"
    a="${frags[0]}"
    b="${frags[@]:1}"
    IFS=',' read -ra tags <<< "${a}"
    id="${tags[0]}"
    msg="data,host=${host},sid=${a} ${b}"
    mosquitto_pub -q 2 -i "sreader" -t "data/${host}/${id}" -m "${msg}"
done
