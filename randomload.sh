#!/bin/sh
range=5
number=$((RANDOM % range))

while true
do
   curl 34.148.75.3 | grep background
   echo "Sleeping 0.$number seconds"
   sleep 0.$number
   number=$((RANDOM % range))
done