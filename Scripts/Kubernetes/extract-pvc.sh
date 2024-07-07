#!/bin/bash

usage_exit() {
    echo "Usage: $0 [-d Deployment] [-i image] PVC ..." 1>&2
    exit 1
}

while getopts i:h OPT
do
    case $OPT in
        i)  IMAGE=$OPTARG
            ;;
        c)  COMMAND=$OPTARG
            ;;
        h)  usage_exit
            ;;
        \?) usage_exit
            ;;
    esac
done
shift $(($OPTIND - 1))

kubectl get pods --no-headers -o custom-columns=":metadata.name" | grep esphome