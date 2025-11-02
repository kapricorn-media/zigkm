#!/bin/bash -e

org=kapricorn-media
repo=$1
dir=$2
service=${PWD##*/}

if [ "$repo" == "" ] || [ "$dir" == "" ]
then
	echo "Required argument <repo> <local dir>"
	exit 1
fi

echo Upgrading latest artifact from repo $org/$repo into local dir $dir.

echo Backing up $dir...
if [ -d "./$dir-bak" ]
then
    if [ -d "./$dir-bak2" ]
    then
        rm -rf "./$dir-bak2"
    fi
    mv "./$dir-bak" "./$dir-bak2"
fi
mv "./$dir" "./$dir-bak"

echo Downloading latest release artifact from $org/$repo...
curl -o latest.zip "https://ci.kapricornmedia.com/latest_artifact?org=$org&repo=$repo"
sha256sum latest.zip
unzip -o latest.zip
tar -xf output_archive.tar.gz
if [ -d "./$dir" ]
then
    echo Download succeeded.
else
    echo Download+extract failed, aborting...
    mv "./$dir-bak" "./$dir"
    exit 1
fi

if [ -d "./$dir-bak/keys" ]
then
    echo Copying keys...
    cp -r "./$dir-bak/keys" "./$dir/keys"
fi
if [ -d "./$dir-bak/state" ]
then
    echo Copying state...
    cp -r "./$dir-bak/state" "./$dir/state"
fi
