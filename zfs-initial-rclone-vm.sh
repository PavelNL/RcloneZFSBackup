#!/usr/bin/bash
#
# INITIAL backup to OneDrive of ProxmoxVE VMs
#
# expected CRONTAB:
#  #Run once all disks of VM #220 (vm-pbs02p)
#  30 7 16 10 *  /etc/SCRIPTS/zfs-initial-rclone-vm.sh 220 xxxxxx_Enc 1>>/var/tmp/zfsrclone_220.log 2>&1

# parameters
vmt=$1 ; vm=${vmt:="2012"}
rclabel=$2

server="$HOSTNAME"
pool="zpool"
volume="vm-2012-disk-0"
frequency="yearly"

# tempdir for rclone
export TMPDIR=/zpool/TMPDIR

# create snapshots
zfs list -H|awk '{print $1}'|awk -F/ '{print $2}'|grep "vm-${vm}-disk-[0-9]"|while read volume ; do
  # check if snapshot exist
  newsnap=$(zfs list -t snapshot $pool/$volume -o name -s creation -H | tail -n1)
  if [[ -z $newsnap ]] ; then 
    snaptag="initial_backup-rclone"
    zfs snapshot ${pool}/${volume}@${snaptag} 1>>/var/tmp/snapshots.log 2>&1
  fi
done

# send
zfs list -H|awk '{print $1}'|awk -F/ '{print $2}'|grep "vm-${vm}-disk-[0-9]"|sort -r|while read volume ; do
  newsnap=$(zfs list -t snapshot $pool/$volume -o name -s creation -H | tail -n1)
  if [[ ! -z $newsnap ]] ; then
    # create checksum file
    ( time nice zfs send -c -w -v $newsnap | md5sum ) 1>/var/tmp/checksum-zfs-$volume.log 2>&1
    # send data: -c, --compressed ; -w, --raw -v, --verbose
    time nice zfs send -c -w -v $newsnap 2>/var/tmp/zfs-send-$volume.log \
    |  nice rclone --low-level-retries 99999 --retries-sleep 30m --config=/etc/rclone.conf \
                   --log-file=/var/tmp/rclone-zfs-$volume.log \
              rcat $rclabel:$server/$newsnap
  fi
done

# compare checksums and remove snapshots if the same
time ( zfs list -t snapshot -o name -s creation -H 2>/dev/null|grep '@initial_backup-rclone'|grep "vm-${vm}-disk"|sort -r|while read newsnap ; do
    # get volume
    volume=$(echo "$newsnap"|sed 's#[/@]# #g'|awk '{print $2}') ; echo "INFO: processing volume: $volume"

    # create checksum file
    md5logsend="/var/tmp/checksum-zfs-send-$volume.log"
    nice zfs send -c -w $newsnap | md5sum 1>$md5logsend 2>&1
    echo "...    checksum SEND: $(grep ' [-]' $md5logsend)"

    # get data from OD
    md5logrecv="/var/tmp/checksum-zfs-recv-$volume.log"
    nice rclone --low-level-retries 99999 --retries-sleep 30m --config=/etc/rclone.conf \
                --log-file=/var/tmp/rclone-zfs-recv-$volume.log  \
          cat $rclabel:$server/$newsnap | md5sum 1>$md5logrecv 2>&1
    echo "...    checksum RECV: $(grep ' [-]' $md5logrecv)"

    # compare checksums and
    rescompare=$(diff -sq "$md5logsend" "$md5logrecv"|grep -c 'identical')
    if [[ $rescompare -eq 1 ]] ; then
      echo "INFO: Sent and Received MD5 are the same. Removing snapshot: $newsnap"
      zfs destroy -pv $newsnap
    else
      echo "ERR: Sent and Received MD5 are NOT the same. Preserving snapshot: $newsnap"
    fi
done
echo "INFO: Snaphots left: "
zfs list -t snapshot -o name -s creation -H|grep '@initial_backup-rclone'
echo "......................" )

echo "...done..."
