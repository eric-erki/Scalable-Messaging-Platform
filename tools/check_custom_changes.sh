#!/bin/sh

[ $# -eq 1 ] || exit
cust=$1
cd /tmp
git clone ssh://git@git.process-one.net:7999/cust/${cust}.git || git clone ssh://git@git.process-one.net:7999/old/${cust}.git || exit
cd ${cust}
git remote add maincustomers ssh://git@git.process-one.net:7999/ebe/maincustomers.git 
git fetch maincustomers
head=$(git describe --tags --always)
base=${head%_*}
mkdir patches
git diff ${base}..${head} > patches/${cust}.diff
git log --oneline --reverse ${base}..${head} | grep -v Merge > patches/${cust}.txt
let n=0
for ref in $(git log --oneline --reverse ${base}..${head} | grep -v Merge | awk '{print $1}')
do
  n=$((n+1))
  file=$(printf "%02d_${ref}.diff" $n)
  git show ${ref} > patches/${file}
done
