# lxborg
A script to make borg backups of lxd instances without writing the full archive on disk temporary


## Usage 

1. modify the script or add a config.txt
2. execute ./lxborg.sh
3. overwrite config with commandline parameters
    -  `-m | --machinename` for the conteriner/vm name
    - `-a | --archivename` for a custom archive name (defaults to `machinename_$(date +%F_%T)`
    - `-s | --snapshotname` for the name of the source snapshot (defaults to `borg`)