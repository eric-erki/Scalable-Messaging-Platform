#!/bin/sh

[ $# -eq 1 ] && since=$1 || {
  since=$(git describe --tags | cut -d'-' -f1)
  since=$(git show $since | sed '/Date/!d;s/Date: *//')
}

check_changes()
{
  git fetch origin
  changes=$(git log --pretty=oneline --since="$since" --remotes -- c_src | wc -l)
  [ $((changes)) -eq 0 ] || echo "* $1"
}

echo "Checking library changes since $since..."
for dep in deps/*/c_src
do
    cd ${dep%/c_src}
    check_changes $(echo $dep | cut -d'/' -f2)
    cd ../..
done
check_changes jlib
echo "Done."
