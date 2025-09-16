#!/bin/bash
while inotifywait -r .; do 
  git add .
  git commit -m "Auto update $(date)"
  git push -u origin main
done
