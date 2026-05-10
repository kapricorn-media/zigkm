#!/bin/bash -e

org=kapricorn-media
repo=$1
service=${PWD##*/}
timestamp=$(date +"%Y-%m-%d_%H-%M-%S")

if [ "$repo" == "" ]
then
	echo "Required argument <repo>"
	exit 1
fi

# echo Upgrading latest artifact from repo $org/$repo into local dir $dir.

# echo Backing up $dir...
# if [ -d "./$dir-bak" ]
# then
#     if [ -d "./$dir-bak2" ]
#     then
#         rm -rf "./$dir-bak2"
#     fi
#     mv "./$dir-bak" "./$dir-bak2"
# fi
# mv "./$dir" "./$dir-bak"

echo Downloading latest release artifact from $org/$repo...
curl -o latest.zip "https://ci.kapricornmedia.com/latest_artifact?org=$org&repo=$repo"
# hash=$(sha256sum latest.zip)
# sha256sum latest.zip
set -- $(sha256sum latest.zip)
hash=$1
unzip -o latest.zip

dir=${timestamp}_${repo}_${hash}
echo Extracting into $dir
echo $timestamp
echo $repo
echo $hash
echo $dir
exit 1

tar -xf output_archive.tar.gz -C $dir
if [ -d "./$dir" ]
then
    echo Download succeeded.
else
    echo Download+extract failed, aborting...
    exit 1
fi

# if [ -d "./$dir-bak/keys" ]
# then
#     echo Copying keys...
#     cp -r "./$dir-bak/keys" "./$dir/keys"
# fi
# if [ -d "./$dir-bak/state" ]
# then
#     echo Copying state...
#     cp -r "./$dir-bak/state" "./$dir/state"
# fi
