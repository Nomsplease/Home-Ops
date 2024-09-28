#!/bin/bash

kubectl delete PersistentVolumeClaim $1

kubectl delete ReplicationSource $1

kubectl delete ReplicationDestination $1-dst