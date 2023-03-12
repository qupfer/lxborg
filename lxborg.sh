#!/bin/bash


#### COPY TO CONFIGFILE ####
### Backup Config ###
machinename=myContainer
snapshotname=borg
archivename=""   # if its empty, the archivename is name_date (myContainer_2023-02-17_07:37:25)
#additonal_tar_args="-v"

### SSH Config ###
ssh_user=root
ssh_host=myhost.domain.com
ssh_port=22
#ssh_key="" # not implemented yet

### BORG CONFIG ###
borg_repo="ssh://${ssh_user}@${ssh_host}:${ssh_port}/data/test_repo"
borg_bin="./borg2b5"
borg_passphrase="abcde"
borg_remote_path="\$HOME/borg_$HOSTNAME"

### LXC CONFIG ###
lxd_path="/var/snap/lxd/common/lxd"
container_snapshot_path="${lxd_path}/snapshots"
vm_snapshot_path="${lxd_path}/virtual-machines-snapshots"

### END COPY TO CONFIGFILE ###

### use external config to overwrite config ###
configfile=config.txt

### EXPORTS ###
# shellcheck source=config.txt
[ -f $configfile ] && source $configfile
export BORG_REMOTE_PATH="$borg_remote_path"
export BORG_BIN=$(realpath "$borg_bin")
export BORG_REPO="$borg_repo"
export BORG_PASSPHRASE="$borg_passphrase"

### commandline options from https://stackoverflow.com/questions/192249/how-do-i-parse-command-line-arguments-in-bash ###

set -o errexit -o pipefail -o noclobber -o nounset

# shellcheck disable=SC2251
! getopt --test > /dev/null 
if [[ ${PIPESTATUS[0]} -ne 4 ]]; then
    echo "I'm sorry, $(getopt --test) failed in this environment."
    exit 1
fi


LONGOPTS=run:,machinename:,snapshotname:,archivename:,configfile:,extract:
OPTIONS=r:m:s:a:c:x:
# -regarding ! and PIPESTATUS see above
# -temporarily store output to be able to check for errors
# -activate quoting/enhanced mode (e.g. by writing out “--options”)
# -pass arguments only via   -- "$@"   to separate them correctly

# shellcheck disable=SC2251
! PARSED=$(getopt --options=$OPTIONS --longoptions=$LONGOPTS --name "$0" -- "$@")
if [[ ${PIPESTATUS[0]} -ne 0 ]]; then
    # e.g. return value is 1
    #  then getopt has complained about wrong arguments to stdout
    exit 2
fi
# read getopt’s output this way to handle the quoting right:
eval set -- "$PARSED"


while true; do
    case "$1" in
        -r|--run)
            #execute=( "$2" )
            IFS=" " read -r -a execute <<< "$2"
            shift 2
            ;;
        -m|--machinename)
            machinename="$2"
            shift 2
            ;;
        -s|--snapshotname)
            snapshotname="$2"
            shift 2
            ;;        
        -a|--archivename)
            archivename="$2"
            shift 2
            ;;
        -c|--configfile)
            configfile="$2"
            shift 2
            ;;
        -x|--extract)
            extract="$2"
            shift 2
            ;;
        --)
            shift
            break
            ;;
        *)
            echo "Programming error"
            exit 3
            ;;
    esac
done



container_prefix=$(cat <<-EOF
name: $machinename
backend: btrfs
pool: default
optimized: false
optimized_header: false
type: container
config:
EOF
)

vm_prefix=$(cat <<-EOF
name: $machinename
backend: btrfs
pool: default
optimized: false
optimized_header: false
type: virtual-machine
config:
EOF
)


if [ -n "${execute-}" ]; then
"$BORG_BIN" "${execute[@]}"
exit 0
fi


if [ -n "${extract-}" ]; then
    tempdir=$(mktemp -d -p .)
    cd "$tempdir"
    
    # extract all
    "$BORG_BIN" extract "$extract"


    # prepare index.yaml
    machinename=$(sed -n '/^container:$/,/^[a-z]*:/p'  "$snapshotname/backup.yaml" | grep -i "^  name: " | cut -d" " -f4)
    info=$(sudo sed 's/^/  /' "$snapshotname/backup.yaml")
    grep -q "type: container" $snapshotname/backup.yaml && { prefix=$container_prefix; mv "$snapshotname" container; }
    grep -q "type: virtual-machine" $snapshotname/backup.yaml && { prefix=$vm_prefix; mv "$snapshotname" virtual-machine ; mv virtual-machine/root.img virtual-machine.img; }
    printf "%s\n%s" "$prefix" "$info"  > "index.yaml"
    sed -in "s/name:.*/name: $machinename/g" index.yaml


    # tar it
    cd ..
    dirname=$(basename "$tempdir")
    tar -c -f "$pwd/${extract}.tar"  --numeric-owner --xattrs --acls --transform "s#$dirname#backup#" "$dirname"
    
    # clean up
    rm -rf $tempdir
    exit 0
fi

[ -z "$archivename" ] && archivename="${machinename}_$(date +%F_%T)"




# make a snapsghot
lxc snapshot "$machinename"  "$snapshotname" --reuse


# container of vm?
type=$(lxc info "$machinename" | grep -i '^Type:' | cut -d' ' -f2)






#prepare info
indexdir=$(mktemp -d)
if [ "$type" == "container" ]; then
    prefix="$container_prefix"
    info=$(sudo sed 's/^/  /' "$container_snapshot_path/$machinename/$snapshotname/backup.yaml")
    snapshot_path="$container_snapshot_path"
    tar_command="sudo tar ${additonal_tar_args-} --numeric-owner --xattrs --acls -c -O  -C "$container_snapshot_path/$machinename/"  --transform "s#^${snapshotname}#backup/container#" $snapshotname -C $indexdir --transform s#^index.yaml#backup/index.yaml#  index.yaml" 

elif [ "$type" == "virtual-machine" ]; then
    prefix="$vm_prefix"
    info=$(sudo sed 's/^/  /' "$vm_snapshot_path/$machinename/$snapshotname/backup.yaml")
    snapshot_path="$vm_snapshot_path"
    tar_command="sudo tar ${additonal_tar_args-} --numeric-owner --spare --xattrs --acls -c -O  -C "$vm_snapshot_path/$machinename/" --transform s#^${snapshotname}#backup/virtual-machine# --transform s#^backup/virtual-machine/root.img#backup/virtual-machine.img#  $snapshotname -C $indexdir --transform s#^index.yaml#backup/index.yaml# index.yaml"
fi


# put borg to destination
remote_sha=$(ssh -p $ssh_port $ssh_user@${ssh_host} "sha256sum $BORG_REMOTE_PATH" | cut -d" " -f1 || echo "")
local_sha=$(sha256sum "$BORG_BIN" | cut -d" " -f1)
[[ $remote_sha == "$local_sha" ]] || scp -P "$ssh_port" "$BORG_BIN" "$ssh_user"@"${ssh_host}":"$BORG_REMOTE_PATH"


# show current archives or create repo 
"$BORG_BIN" rlist || "$BORG_BIN" rcreate --encryption=repokey-aes-ocb 


#BORG IT
#IFS=" " read -r -a tar_execute <<< "$tar_command"
#"$BORG_BIN" create  -s --content-from-command --files-cache=disabled  --list --progress --compression zstd --stdin-name "${archivename}.tar" "$archivename" --  "${tar_execute[@]}"
cd "$snapshot_path/$machinename"
"$BORG_BIN" create  -s  --progress --compression zstd "$archivename" "$snapshotname"
